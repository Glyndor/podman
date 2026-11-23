#!/usr/bin/env bash
#
# Tests for the alert job of .github/workflows/release.yml: a release run that fails
# opens an issue at once, instead of waiting a day for the watchdog. Its condition and
# what it waits for are read from the workflow, and its step is run here with a gh
# that answers from the case and records what it is asked.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

# when <workflow dir>: what the job waits for and when it runs, one line each.
when() {
	python3 - "$1/release.yml" <<'PY' 2>&1 || echo "rule failed"
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["alert"]
print("needs " + " ".join(sorted(job.get("needs") or [])))
print("if " + " ".join(str(job.get("if", "")).split()))
PY
}
check "it waits for every job of the run, and runs when one failed, except on a dispatch" \
	"needs build config-upgrade plan publish rehearsal sign|if \${{ failure() && github.event_name != 'workflow_dispatch' }}" \
	"$(when "$HERE/.github/workflows" | paste -sd'|')"
mkdir -p "$WORK/wf"
sed 's/^    if: \${{ failure() /    if: ${{ success() /' "$HERE/.github/workflows/release.yml" > "$WORK/wf/release.yml"
check "an alarm that runs on success instead is named" "if \${{ success() && github.event_name != 'workflow_dispatch' }}" \
	"$(when "$WORK/wf" | sed -n 2p)"
sed 's/^    needs: \[plan, build, sign, config-upgrade, publish, rehearsal\]$/    needs: [plan, build, sign, config-upgrade, rehearsal]/' "$HERE/.github/workflows/release.yml" > "$WORK/wf/release.yml"
check "one that no longer waits for the publish job is named" "needs build config-upgrade plan rehearsal sign" "$(when "$WORK/wf" | sed -n 1p)"

A="$WORK/alert"
if step release.yml alert "name=Open an issue, or add to the one that is open" "$A"; then
	check "the alert step's run block has no expression in it" 0 "$(grep -c '\${{' "$A/run.sh")"
	mkdir -p "$A/bin"
	cat > "$A/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"issue list") [ -z "${LIST_FAILS:-}" ] || exit 1; echo "list $*" >> "$LOG"; printf '%s\n' "${OPEN_ISSUE:-}" ;;
	"issue create" | "issue comment") echo "$2 $*" >> "$LOG" ;;
	*) exit 1 ;;
esac
GH
	chmod +x "$A/bin/gh"
	alarm() { # [VAR=value]...: sets $rc, and $A/log holds what gh was asked
		: > "$A/log"
		run_step "$A" "$A" PATH="$A/bin:$PATH" LOG="$A/log" GH_TOKEN=a-token GH_REPO=owner/repo \
			RUN_URL=https://example.test/run/7 "$@"
	}
	alarm
	check "no issue open: one is created" "0 1 0" "$rc $(grep -c '^create' "$A/log") $(grep -c '^comment' "$A/log")"
	check "titled for the failure, and found by that title" "1 1" \
		"$(grep -c -- '--title Release run failed ' "$A/log") $(grep -c -F -- '"Release run failed" in:title' "$A/log")"
	check "labelled as a P1 release bug" 1 "$(grep -c -- '--label type:bug --label prio:P1 --label area:release ' "$A/log")"
	check "and it links the run" 1 "$(grep -c 'Read the run: https://example.test/run/7' "$A/log")"
	alarm OPEN_ISSUE=41
	check "an issue already open: a comment on it, and no second issue" "0 1 0" \
		"$rc $(grep -c '^comment issue comment 41 ' "$A/log") $(grep -c '^create' "$A/log")"
	alarm LIST_FAILS=1
	check "the open issues cannot be listed: the job fails instead of opening a duplicate or nothing" "1 0" \
		"$rc $(grep -c '^create\|^comment' "$A/log")"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the alert step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
