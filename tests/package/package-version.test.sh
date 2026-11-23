#!/usr/bin/env bash
#
# Tests for scripts/package/package-version.sh: the version a native package carries is the
# release version with its revision always written, and anything else is refused.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/package/package-version.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

check "the first build of a Podman version is revision 1" "6.2.0+r1" "$(bash "$SCRIPT" 6.2.0)"
check "a later build keeps its revision" "6.2.0+r12" "$(bash "$SCRIPT" 6.2.0+r12)"
check "the second build" "6.2.1+r2" "$(bash "$SCRIPT" 6.2.1+r2)"
for bad in "" v6.2.0 6.2 6.2.0+r 6.2.0+12 6.2.0+r1+r2 6.2.0-1 '6.2.0+r1;x' ' 6.2.0'; do
	bash "$SCRIPT" "$bad" > /dev/null 2>&1; rc=$?
	check "'$bad' is refused" 1 "$rc"
done
check "revision 0 is refused and says why" "a revision starts at 1: 6.2.0+r0" "$(bash "$SCRIPT" 6.2.0+r0 2>&1)"
check "a version that is not one says so" "not a release version: v6.2.0" "$(bash "$SCRIPT" v6.2.0 2>&1)"
# The version of the .deb of the same release, which this one has to be newer than or equal to
# in the way rpm and pacman compare: the revision number of both is the same.
check "the number after +r is the one of the .deb" "12" "$(bash "$SCRIPT" 6.2.0+r12 | sed 's/.*+r//')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
