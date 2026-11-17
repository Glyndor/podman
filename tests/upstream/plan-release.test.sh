#!/usr/bin/env bash
#
# Tests for scripts/upstream/plan-release.sh: when a release is needed and how
# it is named, including a bump of a component under an unchanged Podman.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/plan-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

fresh="$WORK/fresh"
printf 'podman v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\n' > "$fresh"
: > "$WORK/none"

check "first ever release" "build=true tag=v6.2.0" \
	"$("$SCRIPT" "$fresh" "$WORK/none" "$WORK/none" | paste -sd' ')"

printf 'aardvark-dns v2.1.0\npodman v6.2.0\nnetavark v2.1.0\n' > "$WORK/same"
printf 'v6.2.0\n' > "$WORK/t1"
check "nothing changed, in any order" "build=false" "$("$SCRIPT" "$fresh" "$WORK/same" "$WORK/t1")"

printf 'podman v6.2.0\nnetavark v2.0.0\naardvark-dns v2.1.0\n' > "$WORK/old"
check "a component changed under the same podman" "build=true tag=v6.2.0+r2" \
	"$("$SCRIPT" "$fresh" "$WORK/old" "$WORK/t1" | paste -sd' ')"

printf 'v6.2.0\nv6.2.0+r2\nv6.1.4\n' > "$WORK/t2"
check "the counter keeps climbing" "build=true tag=v6.2.0+r3" \
	"$("$SCRIPT" "$fresh" "$WORK/old" "$WORK/t2" | paste -sd' ')"

printf 'podman v6.1.4\nnetavark v2.1.0\naardvark-dns v2.1.0\n' > "$WORK/older"
printf 'v6.1.4\nv6.1.4+r2\n' > "$WORK/t3"
check "a new podman starts at its own version" "build=true tag=v6.2.0" \
	"$("$SCRIPT" "$fresh" "$WORK/older" "$WORK/t3" | paste -sd' ' | sed 's/^build=true //; s/^/build=true /')"

printf 'netavark v2.1.0\n' > "$WORK/nopodman"
"$SCRIPT" "$WORK/nopodman" "$WORK/none" "$WORK/none" >/dev/null 2>&1; check "no podman line fails" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
