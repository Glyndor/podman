#!/usr/bin/env bash
#
# Tests for scripts/monitoring/schedule-freshness.sh: a cron that stops firing is
# caught from its runs, and anything the script cannot read is a failure.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/schedule-freshness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

now="$(date -u -d 2026-11-21T12:00:00Z +%s)"
run() { # <json> [max-hours]: sets $rc and $out
	printf '%s' "$1" > "$WORK/runs.json"
	rc=0
	out="$("$SCRIPT" "$WORK/runs.json" "$now" "${2:-48}" 2>&1)" || rc=$?
}
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

run '[{"createdAt":"2026-11-21T07:30:00Z","conclusion":"success"}]'
check "a run from this morning is fresh" "0 1" "$rc $(says '4 hours old')"
run '[{"createdAt":"2026-11-19T07:30:00Z","conclusion":"success"}]'
check "a run from two days and four hours ago is stale" "1 1" "$rc $(says '52 hours old')"
run '[{"createdAt":"2026-11-19T07:30:00Z","conclusion":"success"}]' 60
check "the same run is fresh under a longer limit" 0 "$rc"

# The newest one counts, whatever order the list comes in.
run '[{"createdAt":"2026-11-10T07:30:00Z","conclusion":"success"},{"createdAt":"2026-11-21T07:30:00Z","conclusion":"success"},{"createdAt":"2026-11-15T07:30:00Z","conclusion":"success"}]'
check "the newest of several runs sets the age" "0 1" "$rc $(says '4 hours old')"

# A red run fired; it has its own alarm, and its silence is not this one's.
run '[{"createdAt":"2026-11-21T07:30:00Z","conclusion":"failure"}]'
check "a run that failed still shows the cron fired" 0 "$rc"
for c in '"cancelled"' '"skipped"' '"startup_failure"' '""' null; do
	run "[{\"createdAt\":\"2026-11-21T07:30:00Z\",\"conclusion\":$c}]"
	check "a run whose conclusion is $c does not count" "1 1" "$rc $(says 'no scheduled run has finished')"
done
run '[{"createdAt":"2026-11-21T07:30:00Z","conclusion":"cancelled"},{"createdAt":"2026-11-18T07:30:00Z","conclusion":"success"}]'
check "a recent cancelled run does not hide an old finished one" "1 1" "$rc $(says '76 hours old')"

run '[]'
check "no runs at all is stale, not fresh" "1 1" "$rc $(says 'no scheduled run has finished')"

# A schedule that began a moment ago has a grace of <max-hours> for its first run.
grace() { # <json> <since>: sets $rc and $out
	printf '%s' "$1" > "$WORK/runs.json"
	rc=0
	out="$("$SCRIPT" "$WORK/runs.json" "$now" 48 "$2" 2>&1)" || rc=$?
}
grace '[]' "$((now - 3600 * 47))"
check "no run yet, from a schedule that began 47 hours ago: inside the grace" "0 1" "$rc $(says 'no scheduled run has finished yet; the schedule began 47 hours ago')"
grace '[]' "$((now - 3600 * 49))"
check "no run yet, 49 hours after it began: a miss" "1 1" "$rc $(says 'no scheduled run has finished')"
grace '[{"createdAt":"2026-11-18T07:30:00Z","conclusion":"success"}]' "$((now - 3600))"
check "a stale run is stale whatever the start says" "1 1" "$rc $(says '76 hours old')"
grace '[]' "$((now + 3600))"
check "a start in the future cannot decide" "2 1" "$rc $(says "is not a time before now")"
grace '[]' yesterday
check "a start that is not a number cannot decide" "2 1" "$rc $(says "the schedule's start 'yesterday' is not a time before now")"

# Cannot read it is a failure, never a pass.
run 'not json'
check "unreadable input is refused" "2 1" "$rc $(says 'cannot read the list of runs')"
run '{"createdAt":"2026-11-21T07:30:00Z","conclusion":"success"}'
check "an object instead of a list is refused" "2 1" "$rc $(says 'cannot read the list of runs')"
run '[{"createdAt":"yesterday","conclusion":"success"}]'
check "a date it cannot parse is refused" "2 1" "$rc $(says 'cannot read the list of runs')"
run '[{"conclusion":"success"}]'
check "a run with no date is refused" "2 1" "$rc $(says 'cannot read the list of runs')"
rc=0; out="$("$SCRIPT" "$WORK/missing.json" "$now" 48 2>&1)" || rc=$?
check "a missing file is refused" "2 1" "$rc $(says 'cannot read the list of runs')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
