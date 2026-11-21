#!/usr/bin/env bash
#
# Tests for the freshness jobs of .github/workflows/watchdog.yml: the daily cron that
# tells the repository upstream changed a signing key, and the weekly mutation sweep,
# are the workflows nothing else watches. Their steps are read from the workflow and
# run here with a gh that answers from a fixture and records what it is asked.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$HERE/.github/workflows/watchdog.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# step <name> <out-dir> [job]: the run block, the literal env values and the if: of
# the step of the job (keyring-watch-freshness by default), which must be exactly one.
step() {
	mkdir -p "$2"
	python3 - "$WF" "${3:-keyring-watch-freshness}" "$1" "$2" <<'PY'
import shlex, sys, yaml
path, job, name, out = sys.argv[1:5]
with open(path) as fh:
    doc = yaml.safe_load(fh)
hits = [s for s in doc["jobs"][job]["steps"] if s.get("name") == name]
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} steps named {name!r} in job {job}")
with open(f"{out}/run.sh", "w") as fh:
    fh.write(hits[0]["run"])
with open(f"{out}/if.txt", "w") as fh:
    fh.write(str(hits[0].get("if", "")))
with open(f"{out}/env.sh", "w") as fh:
    for k, v in (hits[0].get("env") or {}).items():
        if "${{" not in str(v):
            fh.write(f"export {k}={shlex.quote(str(v))}\n")
PY
}

CHECK="$WORK/check"; ALARM="$WORK/alarm"
step "Has the keyring watch run in the last two days" "$CHECK" || { echo "FAIL  cannot read the check step"; exit 1; }
step "Open an issue, or add to the one that is open" "$ALARM" || { echo "FAIL  cannot read the alarm step"; exit 1; }

check "the check's run block has no expression in it" 0 "$(grep -c '\${{' "$CHECK/run.sh")"
check "the alarm's run block has no expression in it" 0 "$(grep -c '\${{' "$ALARM/run.sh")"
check "the alarm opens only on a scheduled run that failed" \
	"failure() && github.event_name == 'schedule'" "$(cat "$ALARM/if.txt")"
check "the workflow it watches is a scheduled one that exists" 1 \
	"$(grep -c '^    - cron:\|^    - cron' "$HERE/.github/workflows/keyring-watch.yml")"

# gh answers `run list` from $RUNS (or fails when RUNS_FAIL is set), `issue list` with
# $OPEN_ISSUE, and records the rest.
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"run list")
		echo "run-list $*" >> "$LOG_DIR/gh"
		[ -z "${RUNS_FAIL:-}" ] || exit 1
		cat "$RUNS" ;;
	"issue list") printf '%s\n' "${OPEN_ISSUE:-}" ;;
	"issue create") echo "create $*" >> "$LOG_DIR/gh" ;;
	"issue comment") echo "comment $*" >> "$LOG_DIR/gh" ;;
	*) exit 1 ;;
esac
GH
chmod +x "$WORK/bin/gh"

run_step() { # <step-dir> [VAR=value]...: sets $rc and $out; the working directory is the repository
	local dir="$1"; shift
	: > "$WORK/gh"; rm -rf "$WORK/rt"; mkdir "$WORK/rt"; : > "$WORK/output"
	rc=0
	out="$(
		cd "$HERE" || exit 99
		# shellcheck source=/dev/null
		. "$dir/env.sh"
		env PATH="$WORK/bin:$PATH" LOG_DIR="$WORK" RUNNER_TEMP="$WORK/rt" GITHUB_OUTPUT="$WORK/output" "$@" \
			bash --noprofile --norc -eo pipefail "$dir/run.sh" 2>&1
	)" || rc=$?
}
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
runs_at() { # <hours ago> <conclusion>
	printf '[{"createdAt":"%s","conclusion":"%s"}]' "$(date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$WORK/runs.json"
}

runs_at 5 success
run_step "$CHECK" RUNS="$WORK/runs.json"
check "a run from five hours ago passes" "0 code=0" "$rc $(cat "$WORK/output")"
check "and it asks for the scheduled runs of keyring-watch.yml" 1 \
	"$(grep -c -- 'run-list run list --workflow keyring-watch.yml --event schedule' "$WORK/gh")"

runs_at 60 success
run_step "$CHECK" RUNS="$WORK/runs.json"
check "a newest run from sixty hours ago fails" "1 code=1" "$rc $(cat "$WORK/output")"
check "and says how old it is" 1 "$(says '60 hours old')"

printf '[]' > "$WORK/runs.json"
run_step "$CHECK" RUNS="$WORK/runs.json"
check "a workflow with no scheduled runs fails" "1 code=1" "$rc $(cat "$WORK/output")"

run_step "$CHECK" RUNS="$WORK/runs.json" RUNS_FAIL=1
check "a gh call that fails is a failure with its own code" "2 code=2" "$rc $(cat "$WORK/output")"
printf 'not json' > "$WORK/runs.json"
run_step "$CHECK" RUNS="$WORK/runs.json"
check "an answer that is not JSON is a failure with its own code" "2 code=2" "$rc $(cat "$WORK/output")"

# The alarm: an issue for a miss, a comment when one is already open.
run_step "$ALARM" CODE=1 RUN_URL=https://example.test/run/1
check "a miss opens an issue named for it" "0 1" "$rc $(grep -c 'create issue create --title The keyring watch has stopped running' "$WORK/gh")"
check "labelled as an upstream P1 bug" 1 "$(grep -c -- '--label type:bug --label prio:P1 --label area:upstream' "$WORK/gh")"
check "and the issue links the run" 1 "$(grep -c 'https://example.test/run/1' "$WORK/gh")"
run_step "$ALARM" CODE=1 RUN_URL=https://example.test/run/2 OPEN_ISSUE=17
check "a second miss comments on the open issue instead" "0 1 0" \
	"$rc $(grep -c 'comment issue comment 17' "$WORK/gh") $(grep -c '^create' "$WORK/gh")"
run_step "$ALARM" CODE=2 RUN_URL=https://example.test/run/3
check "a check that could not decide opens its own issue" "0 1" \
	"$rc $(grep -c "create issue create --title The keyring watch's freshness check could not decide" "$WORK/gh")"

# --- the mutation sweep --------------------------------------------------------------
MCHECK="$WORK/mcheck"; MALARM="$WORK/malarm"
step "Has the mutation sweep run in the last nine days" "$MCHECK" mutation-freshness || { echo "FAIL  cannot read the sweep's check step"; exit 1; }
step "Open an issue, or add to the one that is open" "$MALARM" mutation-freshness || { echo "FAIL  cannot read the sweep's alarm step"; exit 1; }
check "the sweep's check and alarm have no expression in their run blocks" "0 0" \
	"$(grep -c '\${{' "$MCHECK/run.sh") $(grep -c '\${{' "$MALARM/run.sh")"
check "its alarm opens only on a scheduled run that failed" "failure() && github.event_name == 'schedule'" "$(cat "$MALARM/if.txt")"
check "the workflow it watches is a scheduled one that exists" 1 "$(grep -c '^    - cron: ' "$HERE/.github/workflows/mutation.yml")"
# The start of the schedule is read from git: a git that answers $ADDED for the commit
# that added mutation.yml, or nothing.
cat > "$WORK/bin/git" <<'GIT'
#!/usr/bin/env bash
[ "$1 $2" = "log -1" ] || exit 1
printf '%s\n' "${ADDED:-}"
GIT
chmod +x "$WORK/bin/git"
runs_at 30 success
run_step "$MCHECK" RUNS="$WORK/runs.json" ADDED="$(date -d '30 days ago' +%s)"
check "a sweep that ran thirty hours ago passes" "0 code=0" "$rc $(cat "$WORK/output")"
check "and it asks for the scheduled runs of mutation.yml" 1 \
	"$(grep -c -- 'run-list run list --workflow mutation.yml --event schedule' "$WORK/gh")"
runs_at 230 success
run_step "$MCHECK" RUNS="$WORK/runs.json" ADDED="$(date -d '30 days ago' +%s)"
check "one that last ran 230 hours ago fails" "1 code=1 1" "$rc $(cat "$WORK/output") $(says '230 hours old')"
printf '[]' > "$WORK/runs.json"
run_step "$MCHECK" RUNS="$WORK/runs.json" ADDED="$(date -d '2 days ago' +%s)"
check "no run yet, two days after the workflow was added: inside the grace" "0 code=0 1" \
	"$rc $(cat "$WORK/output") $(says 'no scheduled run has finished yet')"
run_step "$MCHECK" RUNS="$WORK/runs.json" ADDED="$(date -d '10 days ago' +%s)"
check "no run yet, ten days after: a miss" "1 code=1" "$rc $(cat "$WORK/output")"
run_step "$MCHECK" RUNS="$WORK/runs.json" ADDED=""
check "no commit that added the workflow: it cannot decide" "2 code=2" "$rc $(cat "$WORK/output")"
run_step "$MCHECK" RUNS="$WORK/runs.json" RUNS_FAIL=1 ADDED="$(date -d '2 days ago' +%s)"
check "a gh call that fails is a failure with its own code" "2 code=2 1" "$rc $(cat "$WORK/output") $(says 'could not list the runs of mutation.yml')"
run_step "$MALARM" CODE=1 RUN_URL=https://example.test/run/4
check "a miss opens an issue named for it, linking the run" "0 1 1" \
	"$rc $(grep -c 'create issue create --title The mutation sweep has stopped running' "$WORK/gh") $(grep -c 'https://example.test/run/4' "$WORK/gh")"
run_step "$MALARM" CODE=2 RUN_URL=https://example.test/run/5 OPEN_ISSUE=21
check "and a second one comments on the open issue" "0 1" "$rc $(grep -c 'comment issue comment 21' "$WORK/gh")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
