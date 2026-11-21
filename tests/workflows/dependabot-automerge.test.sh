#!/usr/bin/env bash
#
# Tests for the guard in .github/workflows/dependabot-automerge.yml that arms
# auto-merge only when every commit on the branch is Dependabot's. The step's own
# run block and its jq program are read from the workflow and run here against a
# gh that answers from a fixture, so what is tested is what the workflow runs.
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

# A failed read stops the job by itself, and so does an answer jq cannot evaluate.
GH_FAILS=1 run_guard '{}'
check "a failed read is refused" "1 0 1" "$rc $merged $(printf '%s' "$out" | grep -c 'could not read the commits')"
run_guard '{"commits":null}'
check "an answer without a list of commits is refused" "1 0 1" "$rc $merged $(printf '%s' "$out" | grep -c 'could not read the commits')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
