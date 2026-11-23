#!/usr/bin/env bash
#
# Tests for scripts/package/pacman/check-replacement.sh with a pacman that answers from the case: what
# Arch has that requires podman is satisfied or replaced, or the build stops and names what is not, and
# a pacman that fails or an empty answer is a failure and not a pass.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/pacman/check-replacement.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin"
cat > "$WORK/bin/pacman" <<'PM'
#!/bin/sh
case "$1" in
	-Sii) [ -z "$FAIL_SII" ] || exit 1; printf 'Name : podman\n'; [ -n "$NO_REQUIRED_BY" ] || printf 'Required By    : %s\n' "${REQUIRED_BY:-None}"; printf 'Optional For   : None\n' ;;
	-Si) [ -z "$FAIL_SI" ] || exit 1; printf 'Name : %s\nDepends On     : %s\n' "$2" "$(cat "$DEPS/dep-$2" 2> /dev/null || echo None)" ;;
esac
PM
chmod +x "$WORK/bin/pacman"
export DEPS="$WORK"
PATH="$WORK/bin:$PATH"
run() { out="$("$SCRIPT" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

REQUIRED_BY="podman-docker" run
check "only podman-docker, which is ours, passes" 0 "$rc"
echo "glibc podman>=1.0" > "$WORK/dep-loose"
REQUIRED_BY="podman-docker  loose" run
check "a requirement with no epoch is satisfied" 0 "$rc"
echo "glibc podman=6.1.0-1" > "$WORK/dep-exact"
REQUIRED_BY="podman-docker exact" run
check "a package that requires an exact version stops the build, and is named" "1 1" "$rc $(says 'exact requires podman exactly (6.1.0-1)')"
echo "podman>=2:6.0" > "$WORK/dep-epoch"
REQUIRED_BY="podman-docker epoch" run
check "a requirement at an epoch stops the build" "1 1" "$rc $(says 'epoch requires podman at an epoch (2:6.0)')"
REQUIRED_BY="None" run
check "an answer that says nobody requires podman is refused: podman-docker does" "1 1" "$rc $(says 'do not list podman-docker')"
REQUIRED_BY="loose" run
check "an answer without podman-docker is refused" "1 1" "$rc $(says 'do not list podman-docker')"
NO_REQUIRED_BY=1 run
check "an answer with no line about what requires podman is refused" "1 1" "$rc $(says 'say nothing of what requires podman')"
FAIL_SII=1 REQUIRED_BY="podman-docker" run
check "a pacman that cannot answer stops the build" "1 1" "$rc $(says 'cannot ask the repositories about podman')"
FAIL_SI=1 REQUIRED_BY="podman-docker exact" run
check "a pacman that cannot say what a package depends on stops the build" "1 1" "$rc $(says 'cannot ask the repositories about exact')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
