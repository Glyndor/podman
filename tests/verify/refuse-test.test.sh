#!/usr/bin/env bash
#
# Tests for scripts/verify/refuse-test.sh. Only the argument contract runs here:
# the refusal needs root inside an Ubuntu 22.04 container and is exercised by the
# release workflow, not by this suite.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/refuse-test.sh"
pass=0; fail=0

check() { # <desc> <want-exit> <got-exit>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want exit $2, got $3)"; fi
}

"$SCRIPT" >/dev/null 2>&1; [ $? -ne 0 ]; check "no arguments fails" 0 "$?"
"$SCRIPT" /nonexistent.deb >/dev/null 2>&1; check "missing deb fails with 2" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
