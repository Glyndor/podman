#!/usr/bin/env bash
#
# Tests for scripts/package/verify/pacman-test.sh as far as a stand-in reaches: its argument contract.
# It installs the packages with pacman, as root, in a privileged Arch container, and nothing here can be
# that; its real run is in .github/workflows/reusable-package.yml, which package-check.yml runs on a
# pull request that changes how the packages are built and release.yml runs before anything is signed.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/verify/pacman-test.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/pkgs"
img=quay.io/libpod/alpine@sha256:fa93b01658e3a5a1686dc3ae55f170d8de487006fb53a28efcd12ab0710a2e5f
bash "$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"
bash "$SCRIPT" "$WORK/pkgs" 6.2.0+r12 6.2.0 sideways "$img" > /dev/null 2>&1; check "a mode that is neither clean nor upgrade is a usage error" 2 "$?"
bash "$SCRIPT" "$WORK/pkgs" 6.2.0 6.2.0 clean "$img" > /dev/null 2>&1; check "a version with no revision is a usage error" 2 "$?"
bash "$SCRIPT" "$WORK/absent" 6.2.0+r12 6.2.0 clean "$img" > /dev/null 2>&1; check "a directory of packages that is not there is refused" 1 "$?"
# A machine with bash and a few basics lacks the programs of the proof: it is refused, they are named, and nothing ran.
mkdir "$WORK/bare"
for tool in bash awk grep sed tr sort dirname cat head; do ln -s "$(type -P "$tool")" "$WORK/bare/$tool"; done
out="$(PATH="$WORK/bare" "$WORK/bare/bash" "$SCRIPT" "$WORK/pkgs" 6.2.0+r12 6.2.0 clean "$img" 2>&1)"; rc=$?
check "a machine without the programs of the proof is refused" "1" "$rc"
check "and runuser, useradd, newuidmap, getcap, pacman and repo-add are named, and rpm is not asked of it" "runuser useradd newuidmap getcap pacman repo-add 0" \
	"$(printf '%s\n' "$out" | sed -n 's/^this container lacks://p' | tr ' ;' '\n\n' | grep -x -e runuser -e useradd -e newuidmap -e getcap -e pacman -e repo-add | paste -sd' ') $(printf '%s\n' "$out" | sed -n 's/^this container lacks://p' | tr ' ;' '\n\n' | grep -c -x rpm)"
check "and nothing of the proof ran" 0 "$(printf '%s\n' "$out" | grep -c '^== ')"
check "the proof does not use su, which a minimal image lacks" 0 "$(grep -v '^\s*#' "$HERE/scripts/package/verify/runtime-checks.sh" | grep -c -E '(^|[^a-z_-])su (probe|-)')"
check "the command of the README is the one the test runs" 1 "$(grep -c 'pacman -Syu --needed --noconfirm podman' "$SCRIPT")"
check "and the repository is listed before core" 1 "$(grep -c 'i \[glyndor\]' "$SCRIPT")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
