#!/usr/bin/env bash
#
# Tests for scripts/verify/package-state.sh, the checks of smoke-test.sh about what the
# package left on the system: the seccomp profile is this release's, the distribution's
# copy of what the package replaces is gone, and buildah and skopeo survived. dpkg-query
# is faked with a list of packages and their status, so each check is run both ways,
# and every refusal is asserted by what it says, not only by its exit code.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/package-state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# A dpkg-query that answers -W -f='${Status}' <package> from $FAKE_DPKG, one
# "<package> <status words>" per line, and finds nothing for a package not listed.
mkdir "$WORK/bin"
cat > "$WORK/bin/dpkg-query" <<'DPKGQ'
#!/bin/sh
[ "$1 $2" = '-W -f=${Status}' ] || exit 2
pkg="$3"
line="$(grep "^$pkg " "$FAKE_DPKG")" || exit 1
printf '%s' "${line#"$pkg" }"
DPKGQ
chmod +x "$WORK/bin/dpkg-query"
state() { printf '%s\n' "$@" > "$WORK/dpkg"; }

run() { # <args...>: sets $rc and $err
	rc=0
	err="$(PATH="$WORK/bin:$PATH" FAKE_DPKG="$WORK/dpkg" GLYNDOR_SECCOMP_PROFILE="$WORK/seccomp.json" bash "$SCRIPT" "$@" 2>&1 >/dev/null)" || rc=$?
}
said() { printf '%s\n' "$err" | grep -c -x -F -- "$1"; }

# --- the seccomp profile is the one of this release --------------------------------
echo '{"syscalls":[{"names":["futex_wait","futex_waitv","futex_wake"]}]}' > "$WORK/seccomp.json"
run seccomp
check "a profile with futex_waitv is this release's" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
echo '{"syscalls":[{"names":["futex","futex_wait"]}]}' > "$WORK/seccomp.json"
run seccomp
check "an older profile, with futex_wait and no futex_waitv, is refused" "1 1" "$rc $(said "the seccomp profile is not this release's")"
rm "$WORK/seccomp.json"
run seccomp
check "no profile at all is refused for the same reason, not read as fine" "1 1" "$rc $(said "the seccomp profile is not this release's")"

# --- the distribution's copy is not installed next to the package ------------------
state "podman install ok installed"
run replaced golang-github-containers-common
check "a distribution package that is not listed passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
state "golang-github-containers-common deinstall ok config-files"
run replaced golang-github-containers-common
check "one that was removed and left its configuration passes" 0 "$rc"
state "golang-github-containers-common install ok installed"
run replaced golang-github-containers-common
check "one that is installed is refused" "1 1" "$rc $(said "the distribution's golang-github-containers-common is installed next to this package")"
state "golang-github-containers-common install ok installed" "passt install ok installed"
run replaced passt
check "the same check on passt names passt" "1 1" "$rc $(said "the distribution's passt is installed next to this package")"
state "passt install ok installed"
run replaced golang-github-containers-common
check "and a different package installed does not stand in for the one asked about" 0 "$rc"

# --- buildah and skopeo survive the upgrade ----------------------------------------
state "buildah install ok installed" "skopeo install ok installed"
run kept buildah skopeo
check "both installed passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
state "buildah install ok installed"
run kept buildah skopeo
check "skopeo gone is refused, and named" "1 1" "$rc $(said "skopeo was removed by the upgrade")"
state "skopeo install ok installed"
run kept buildah skopeo
check "buildah gone is refused, and named" "1 1" "$rc $(said "buildah was removed by the upgrade")"
state "buildah deinstall ok config-files" "skopeo install ok installed"
run kept buildah skopeo
check "buildah removed with its configuration left is refused" "1 1" "$rc $(said "buildah was removed by the upgrade")"

# --- usage ------------------------------------------------------------------------
run
check "no check is a usage error" 2 "$rc"
run nothing
check "an unknown check is a usage error" 2 "$rc"
run replaced
check "replaced without a package is a usage error" 2 "$rc"
run kept
check "kept without a package is a usage error" 2 "$rc"
run seccomp extra
check "seccomp with an argument is a usage error" 2 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
