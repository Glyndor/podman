#!/usr/bin/env bash
#
# Tests for scripts/upstream/keyring-diff.sh: any difference between the keys
# this repository trusts and the ones upstream publishes is reported.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/keyring-diff.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/ours" "$WORK/up"
echo one > "$WORK/ours/a.asc"; echo two > "$WORK/ours/b.asc"
cp "$WORK/ours/"*.asc "$WORK/up/"

out="$("$SCRIPT" "$WORK/ours" "$WORK/up")"; rc=$?
check "identical directories pass" 0 "$rc"
check "and print nothing" "" "$out"

echo three > "$WORK/up/c.asc"
out="$("$SCRIPT" "$WORK/ours" "$WORK/up")"; rc=$?
check "a key upstream added is a difference" 1 "$rc"
check "and is named" "added c.asc" "$out"

rm "$WORK/up/c.asc"; echo renewed > "$WORK/up/a.asc"
out="$("$SCRIPT" "$WORK/ours" "$WORK/up")"; rc=$?
check "a renewed key is a difference" 1 "$rc"
check "and is named as changed" "changed a.asc" "$out"

cp "$WORK/ours/a.asc" "$WORK/up/a.asc"; rm "$WORK/up/b.asc"
out="$("$SCRIPT" "$WORK/ours" "$WORK/up")"; rc=$?
check "a key upstream removed is a difference" 1 "$rc"
check "and is named as removed" "removed b.asc" "$out"

"$SCRIPT" "$WORK/ours" "$WORK/missing" >/dev/null 2>&1; check "a missing directory is exit 2" 2 "$?"
"$SCRIPT" >/dev/null 2>&1; check "no arguments fails" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
