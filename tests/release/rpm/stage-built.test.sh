#!/usr/bin/env bash
#
# Tests for scripts/release/rpm/stage-built.sh: what the build of one leg left has to be exactly its packages, and
# their hashes are printed from the copy that is uploaded.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/release/rpm/stage-built.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
# shellcheck source=tests/lib/rpm-set.sh
. "$HERE/tests/lib/rpm-set.sh"

NAMES="$(bash "$HERE/scripts/release/rpm/names.sh" leg 6.2.1+r6 el9 x86_64)"
one=podman-6.2.1+r6-6.glyndor.el9.x86_64.rpm
fresh() {
	rm -rf "$WORK/built" "$WORK/stage"; mkdir "$WORK/built"
	local n
	while IFS= read -r n; do fake_rpm "$WORK/built/$n"; done <<< "$NAMES"
}
stage() { out="$(bash "$SCRIPT" 6.2.1+r6 el9 x86_64 "$WORK/built" "$WORK/stage" 2> "$WORK/err")"; rc=$?; err="$(cat "$WORK/err")"; }
errs() { printf '%s\n' "$err" | grep -c -F -- "$1"; }
refused() { check "$1" "1 1 absent" "$rc $(errs "$2") $([ -e "$WORK/stage" ] && [ -n "$(ls -A "$WORK/stage")" ] && echo staged || echo absent)"; }

fresh; stage
check "exactly the packages of the leg: they are staged" "0 $(sort <<< "$NAMES" | paste -sd' ')" "$rc $(cd "$WORK/stage" && find . -type f -printf '%P\n' | sort | paste -sd' ')"
want=""; while IFS= read -r n; do want+="$n=$(sha256sum "$WORK/built/$n" | cut -d' ' -f1) "; done <<< "$NAMES"
check "and the one line printed is each name with the sha256 of the file" "${want% }" "$out"
fresh; mkdir "$WORK/stage"; stage
check "an empty stage directory is used" 0 "$rc"
fresh; rm "$WORK/built/$one"; stage
refused "a package the build did not leave is refused" "did not leave exactly its packages"
fresh; fake_rpm "$WORK/built/extra.rpm"; stage
refused "a file of more is refused" "did not leave exactly its packages"
fresh; mkdir "$WORK/built/sub"; stage
refused "a directory is refused" "did not leave exactly its packages"
fresh; rm "$WORK/built/$one"; ln -s /etc/hostname "$WORK/built/$one"; stage
refused "a link in place of a package is refused" "did not leave exactly its packages"
fresh; truncate -s 301M "$WORK/built/$one"; stage
refused "a package over the cap is refused" "is over the size cap"
fresh; mkdir "$WORK/stage"; : > "$WORK/stage/old"; stage
check "a stage directory with something in it is refused" "1 1" "$rc $(errs 'is not an empty directory')"
fresh; mkdir "$WORK/real"; ln -s "$WORK/real" "$WORK/stage"; stage
check "a stage that is a link is refused" "1 1" "$rc $(errs 'is not an empty directory')"
rm -f "$WORK/stage"; rm -rf "$WORK/built"; stage
check "no build directory is refused" "1 1" "$rc $(errs 'is not a directory')"
fresh; mv "$WORK/built" "$WORK/elsewhere"; ln -s "$WORK/elsewhere" "$WORK/built"; stage
check "a build directory that is a link is refused" "1 1" "$rc $(errs 'is not a directory')"
rm -f "$WORK/built"; fresh
out="$(bash "$SCRIPT" 6.2.1+r6 fc43 x86_64 "$WORK/built" "$WORK/stage" 2>&1)"; rc=$?
check "a leg that cannot be named is refused" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'cannot be named')"
bash "$SCRIPT" 6.2.1 el9 > /dev/null 2>&1; check "too few arguments is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
