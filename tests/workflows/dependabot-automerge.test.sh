#!/usr/bin/env bash
#
# Tests for the guard in .github/workflows/dependabot-automerge.yml that arms
# auto-merge only when every commit on the branch is Dependabot's. The step's own
# run block and its jq program are read from the workflow and run here against a
# gh that answers from a fixture, so what is tested is what the workflow runs. The
# if: of the arm and disarm jobs is evaluated too, for who opened the pull request
# and who pushed: a person's push must disarm, and must never arm.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$HERE/.github/workflows/dependabot-automerge.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# Writes the run block of the step to $WORK/run.sh and its env values that are not
# expressions to $WORK/env.sh. Fails loudly when the step is not exactly one.
python3 - "$WF" arm "Merge when the required checks pass" "$WORK" <<'PY' || { echo "FAIL  cannot read the step"; exit 1; }
import shlex, sys, yaml
path, job, name, out = sys.argv[1:5]
with open(path) as fh:
    steps = yaml.safe_load(fh)["jobs"][job]["steps"]
hits = [s for s in steps if s.get("name") == name]
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} steps named {name!r} in job {job}")
with open(f"{out}/run.sh", "w") as fh:
    fh.write(hits[0]["run"])
with open(f"{out}/env.sh", "w") as fh:
    for k, v in (hits[0].get("env") or {}).items():
        if "${{" not in str(v):
            fh.write(f"export {k}={shlex.quote(str(v))}\n")
PY

check "the run block has no expression in it" 0 "$(grep -c '\${{' "$WORK/run.sh")"
check "the jq program is a literal in the step's env" 1 "$(grep -c '^export ONLY_DEPENDABOT=' "$WORK/env.sh")"
check "and so is the one that reads the files" 1 "$(grep -c '^export SIGNING_TOOLS=' "$WORK/env.sh")"

# gh answers `pr view --json commits --jq <program>` by running that program over
# $FIXTURE with jq, as gh does with its own jq, and records every merge it is asked for.
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"pr view")
		[ -z "${GH_FAILS:-}" ] || exit 1
		# FILES_ANSWER stands for a gh that answers the files query with something its
		# program cannot print, so the arm that refuses an answer it does not know runs.
		case " $* " in *" --json files "*) [ -z "${FILES_ANSWER+set}" ] || { printf '%s' "$FILES_ANSWER"; exit 0; } ;; esac
		while [ $# -gt 0 ]; do [ "$1" = --jq ] && { jq -r "$2" "$FIXTURE"; exit; }; shift; done
		exit 1 ;;
	"pr merge") echo "merge $*" >> "$GH_LOG" ;;
	*) exit 1 ;;
esac
GH
chmod +x "$WORK/bin/gh"

run_guard() { # <fixture json>; sets $rc, $out and $merged
	printf '%s' "$1" > "$WORK/fixture.json"
	: > "$WORK/gh.log"
	rc=0
	out="$(
		# shellcheck source=/dev/null
		. "$WORK/env.sh"
		PATH="$WORK/bin:$PATH" FIXTURE="$WORK/fixture.json" GH_LOG="$WORK/gh.log" \
			NUMBER=7 TITLE="Bump x" HEAD_SHA=abc123 \
			bash --noprofile --norc -eo pipefail "$WORK/run.sh" 2>&1
	)" || rc=$?
	merged="$(grep -c '^merge' "$WORK/gh.log")"
}
dep='{"login":"dependabot[bot]","name":"dependabot[bot]","email":"49699333+dependabot[bot]@users.noreply.github.com"}'

other='"files":[{"path":".github/workflows/tests.yml"},{"path":"scripts/build/Dockerfile"}]'
run_guard "{\"commits\":[{\"authors\":[$dep]},{\"authors\":[$dep]}],$other}"
check "every commit by Dependabot arms auto-merge" "0 1" "$rc $merged"
check "and the merge is tied to the commit that was checked" 1 "$(grep -c -- '--match-head-commit abc123' "$WORK/gh.log")"

run_guard "{\"commits\":[{\"authors\":[{\"login\":\"app/dependabot\"}]}],$other}"
check "Dependabot's app login is Dependabot too" "0 1" "$rc $merged"

# The tools that sign a release are not merged by a machine: the job ends well and
# arms nothing, so the pull request waits for a person.
by_hand() { # <desc> <files json>
	run_guard "{\"commits\":[{\"authors\":[$dep]}],\"files\":$2}"
	check "$1 is left for a person" "0 0 1" "$rc $merged $(printf '%s' "$out" | grep -c 'changes the signing tools')"
}
by_hand "a bump of the signing library" '[{"path":".github/scripts/release/sign-requirements.txt"}]'
by_hand "a bump that also touches something else" '[{"path":".github/workflows/tests.yml"},{"path":".github/scripts/release/sign.py"}]'
run_guard "{\"commits\":[{\"authors\":[$dep]}],\"files\":[{\"path\":\"docs/.github/scripts/release/x\"}]}"
check "a path that only contains that folder's name is not it" "0 1" "$rc $merged"
run_guard "{\"commits\":[{\"authors\":[$dep]}]}"
check "an answer without a list of files is refused" "1 0 1" "$rc $merged $(printf '%s' "$out" | grep -c 'could not read the files')"

refused() { # <desc> <fixture>
	run_guard "$2"
	check "$1 is refused" "1 0 1" "$rc $merged $(printf '%s' "$out" | grep -c 'is not Dependabot.s alone, or has no author')"
}
refused "a commit with no author" "{\"commits\":[{\"authors\":[$dep]},{\"authors\":[]}]}"
refused "a commit whose authors are missing" "{\"commits\":[{\"authors\":[$dep]},{}]}"
refused "a branch with no commits" '{"commits":[]}'
refused "a commit by a person" "{\"commits\":[{\"authors\":[$dep]},{\"authors\":[{\"login\":\"someone\"}]}]}"
refused "a commit Dependabot shares with a person" "{\"commits\":[{\"authors\":[$dep,{\"login\":\"someone\"}]}]}"
refused "an author linked to no account" '{"commits":[{"authors":[{"login":"","email":"x@example.org"}]}]}'
refused "an author with a null login" '{"commits":[{"authors":[{"login":null}]}]}'

for answer in "" "maybe" "untouched touched"; do
	FILES_ANSWER="$answer" run_guard "{\"commits\":[{\"authors\":[$dep]}]}"
	check "an answer about the files that is neither touched nor untouched ('$answer') is refused" "1 0 1" \
		"$rc $merged $(printf '%s' "$out" | grep -c "unexpected answer reading the files: '$answer'")"
done

# A failed read stops the job by itself, and so does an answer jq cannot evaluate.
GH_FAILS=1 run_guard '{}'
check "a failed read is refused" "1 0 1" "$rc $merged $(printf '%s' "$out" | grep -c 'could not read the commits')"
run_guard '{"commits":null}'
check "an answer without a list of commits is refused" "1 0 1" "$rc $merged $(printf '%s' "$out" | grep -c 'could not read the commits')"

# --- which job runs: arm when Dependabot pushed, disarm when anybody else did ----------
# The if: of each job is read from the workflow and evaluated for each event below,
# so it is what the condition decides that is held, not its spelling. Only the form
# these conditions use is understood, terms of `<context> == or != '<literal>'` joined
# by &&; anything else is "unreadable", never true or false.
jobs_for() { # <workflow> <event> <pull request author> <actor>: the jobs that would run
	python3 - "$@" <<'PY' 2>&1 || echo "rule failed"
import re, sys, yaml
path, event, author, actor = sys.argv[1:5]
ctx = {"github.event_name": event, "github.event.pull_request.user.login": author, "github.actor": actor}
jobs = yaml.safe_load(open(path))["jobs"]
term = re.compile(r"\s*([a-z_.]+)\s*(==|!=)\s*'([^']*)'\s*")
ran = []
for name in ("arm", "disarm"):
    cond = str(jobs[name].get("if", "")).strip()
    cond = re.sub(r"^\$\{\{(.*)\}\}$", r"\1", cond)
    value = True
    for part in cond.split("&&"):
        m = term.fullmatch(part)
        if not m or m.group(1) not in ctx:
            print(f"{name}: unreadable condition {cond!r}")
            break
        value = value and ((ctx[m.group(1)] == m.group(3)) == (m.group(2) == "=="))
    else:
        if value:
            ran.append(name)
print(" ".join(ran) or "none")
PY
}
bot='dependabot[bot]'
check "Dependabot pushed to its own pull request: arm, and only arm" "arm" "$(jobs_for "$WF" pull_request_target "$bot" "$bot")"
check "a person pushed to Dependabot's pull request: disarm, and only disarm" "disarm" "$(jobs_for "$WF" pull_request_target "$bot" someone)"
check "a person's own pull request: neither" "none" "$(jobs_for "$WF" pull_request_target someone someone)"
check "Dependabot pushing to a person's pull request: neither" "none" "$(jobs_for "$WF" pull_request_target someone "$bot")"
check "a push to main: neither" "none" "$(jobs_for "$WF" push "" someone)"
swapped="$WORK/swapped.yml"
sed "s/ \&\& github.actor == 'dependabot\[bot\]'\$/ \&\& github.actor == 'X'/; s/ \&\& github.actor != 'dependabot\[bot\]'\$/ \&\& github.actor == 'dependabot[bot]'/; s/ \&\& github.actor == 'X'\$/ \&\& github.actor != 'dependabot[bot]'/" "$WF" > "$swapped"
check "the fixture did swap the two conditions" "1 1" \
	"$(grep -c "^    if: .* && github.actor != 'dependabot\[bot\]'\$" "$swapped") $(grep -c "^    if: .* && github.actor == 'dependabot\[bot\]'\$" "$swapped")"
check "with them swapped, a person's push would arm the merge, which the cases above refuse" "arm" "$(jobs_for "$swapped" pull_request_target "$bot" someone)"
sed "s/^\(    if: github.event_name == 'pull_request_target' && github.event.pull_request.user.login == 'dependabot\[bot\]'\) && github.actor != 'dependabot\[bot\]'\$/\1/" "$WF" > "$swapped"
check "a disarm that stops looking at who pushed also runs on Dependabot's own push" "arm disarm" "$(jobs_for "$swapped" pull_request_target "$bot" "$bot")"
sed "s/^    if: github.event_name == 'pull_request_target' && github.event.pull_request.user.login == 'dependabot\[bot\]' && github.actor != /    if: always() \&\& github.actor != /" "$WF" > "$swapped"
check "a condition outside the form this reads is unreadable, not an answer" "disarm: unreadable condition \"always() && github.actor != 'dependabot[bot]'\"
arm" "$(jobs_for "$swapped" pull_request_target "$bot" "$bot")"

# --- disarm: auto-merge goes off when it was on, and a failed read is a refusal --------
# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"
D="$WORK/disarm"
if step dependabot-automerge.yml disarm "name=Turn auto-merge off" "$D"; then
	check "the disarm step's run block has no expression in it" 0 "$(grep -c '\${{' "$D/run.sh")"
	mkdir -p "$D/bin"
	cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"pr view") [ -z "${GH_FAILS:-}" ] || exit 1; printf '%s\n' "$ARMED" ;;
	"pr merge") echo "merge $*" >> "$GH_LOG" ;;
	*) exit 1 ;;
esac
GH
	chmod +x "$D/bin/gh"
	disarm() { : > "$D/gh.log"; run_step "$D" "$D" PATH="$D/bin:$PATH" GH_LOG="$D/gh.log" NUMBER=7 "$@"; }
	disarm ARMED=true
	check "armed: auto-merge is turned off for that pull request" "0 1" "$rc $(grep -c -x 'merge pr merge 7 --disable-auto' "$D/gh.log")"
	disarm ARMED=false
	check "not armed: nothing to turn off, and it says so" "0 0 1" "$rc $(grep -c . "$D/gh.log") $(says 'auto-merge was not on')"
	disarm ARMED=true GH_FAILS=1
	check "a pull request that cannot be read is refused, and nothing is turned off by guess" "1 1 0" \
		"$rc $(says 'could not read the pull request') $(grep -c . "$D/gh.log")"
else
	fail=$((fail + 1)); echo "FAIL  dependabot-automerge.yml: cannot find the disarm step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
