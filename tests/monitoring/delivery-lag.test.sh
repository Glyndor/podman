#!/usr/bin/env bash
#
# Tests for scripts/monitoring/delivery-lag.sh: it decides from the result, so a
# stalled pipeline is caught however it stalled.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/delivery-lag.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

now=1000000000
hour=3600
printf 'podman v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\nrecipe aaa\n' > "$WORK/released"
printf 'v6.2.0\n' > "$WORK/tags"
run() { "$SCRIPT" "$WORK/fresh" "$WORK/released" "$WORK/tags" "$WORK/dates" "$now" "${1:-24}"; }

cp "$WORK/released" "$WORK/fresh"; : > "$WORK/dates"
run >/dev/null 2>&1; check "up to date passes" 0 "$?"

printf 'podman v6.3.0\nnetavark v2.1.0\naardvark-dns v2.1.0\nrecipe aaa\n' > "$WORK/fresh"
printf 'podman v6.3.0 %d\n' $((now - 3 * hour)) > "$WORK/dates"
out="$(run 2>&1)"; check "behind for three hours passes" 0 "$?"
check "and says how long" 1 "$(printf '%s' "$out" | grep -c 'for 3 hours')"

printf 'podman v6.3.0 %d\n' $((now - 30 * hour)) > "$WORK/dates"
out="$(run 2>&1)"; rc=$?
check "behind for thirty hours fails" 1 "$rc"
check "and names the component that is missing" 1 "$(printf '%s' "$out" | grep -c 'not yet released: podman')"

check "the same lag passes under a longer limit" 0 "$(run 48 >/dev/null 2>&1; echo $?)"

# Several components: the oldest of the missing ones starts the clock. A newer
# component must not hide a stalled one.
printf 'podman v6.3.0\nnetavark v2.2.0\naardvark-dns v2.1.0\nrecipe aaa\n' > "$WORK/fresh"
printf 'podman v6.3.0 %d\nnetavark v2.2.0 %d\n' $((now - 90 * hour)) $((now - 2 * hour)) > "$WORK/dates"
out="$(run 2>&1)"; rc=$?
check "the oldest missing component sets the clock" 1 "$rc"
check "and says it has waited ninety hours" 1 "$(printf '%s' "$out" | grep -c 'for 90 hours')"
printf 'podman v6.3.0 %d\nnetavark v2.2.0 %d\n' $((now - 20 * hour)) $((now - 2 * hour)) > "$WORK/dates"
run >/dev/null 2>&1; check "two recent components pass" 0 "$?"

# A line the release carries and upstream no longer has is not a stall.
printf 'podman v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\nrecipe aaa\nold-thing v1\n' > "$WORK/released"
cp "$WORK/fresh" "$WORK/fresh.keep"; printf 'podman v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\nrecipe aaa\n' > "$WORK/fresh"; : > "$WORK/dates"
out="$(run 2>&1)"; rc=$?
check "a line only the release has is not an alarm" 0 "$rc"
check "and does not print a meaningless number of hours" 0 "$(printf '%s' "$out" | grep -c 'hours')"
printf 'podman v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\nrecipe aaa\n' > "$WORK/released"; cp "$WORK/fresh.keep" "$WORK/fresh"

# A change in how the package is built counts like an upstream release.
cp "$WORK/released" "$WORK/fresh"; sed -i 's/recipe aaa/recipe bbb/' "$WORK/fresh"
printf 'recipe bbb %d\n' $((now - 50 * hour)) > "$WORK/dates"
out="$(run 2>&1)"; rc=$?
check "a packaging change nobody released fails" 1 "$rc"
check "and says recipe" 1 "$(printf '%s' "$out" | grep -c 'recipe')"

# Undecidable inputs are an error, never a pass.
printf 'podman v6.3.0\nnetavark v2.1.0\naardvark-dns v2.1.0\nrecipe aaa\n' > "$WORK/fresh"; : > "$WORK/dates"
run >/dev/null 2>&1; check "a missing date is exit 2" 2 "$?"

cp "$WORK/released" "$WORK/fresh"; : > "$WORK/dates"
"$SCRIPT" "$WORK/fresh" /dev/null "$WORK/tags" "$WORK/dates" "$now" 24 >/dev/null 2>&1
check "tags without readable released components is exit 2" 2 "$?"

"$SCRIPT" >/dev/null 2>&1; check "no arguments fails" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
