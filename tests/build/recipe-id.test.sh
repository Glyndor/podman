#!/usr/bin/env bash
#
# Tests for scripts/build/recipe-id.sh: the id follows the content of the build
# directory and nothing else.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/build/recipe-id.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/a" "$WORK/b"
printf 'one\n' > "$WORK/a/x"; printf 'one\n' > "$WORK/b/x"

id_a="$("$SCRIPT" "$WORK/a")"
check "the id is twelve hex characters" 1 "$(printf '%s' "$id_a" | grep -c -E '^[0-9a-f]{12}$')"
check "the same content gives the same id in another directory" "$id_a" "$("$SCRIPT" "$WORK/b")"
check "running it twice gives the same id" "$id_a" "$("$SCRIPT" "$WORK/a")"

printf 'two\n' > "$WORK/b/x"
check "changing a file changes the id" 1 "$([ "$id_a" != "$("$SCRIPT" "$WORK/b")" ] && echo 1 || echo 0)"

printf 'one\n' > "$WORK/b/x"; printf 'extra\n' > "$WORK/b/y"
check "adding a file changes the id" 1 "$([ "$id_a" != "$("$SCRIPT" "$WORK/b")" ] && echo 1 || echo 0)"

"$SCRIPT" "$WORK/missing" >/dev/null 2>&1
check "a missing directory fails with 2" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
