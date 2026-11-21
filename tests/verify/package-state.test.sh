#!/usr/bin/env bash
#
# Tests for scripts/verify/package-state.sh, the checks of smoke-test.sh about what the
# package left on the system: the seccomp profile is this release's, the distribution's
# copy of what the package replaces is gone, and buildah and skopeo survived; and the two
# about its network stack: pasta has the option Podman passes, and two containers find
# each other by name. dpkg-query, pasta and podman are faked, so each check is run both
# ways, and every refusal is asserted by what it says, not only by its exit code.
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

# --- pasta has the option Podman passes --------------------------------------------
# A pasta that prints $PASTA_HELP for --help and exits with $PASTA_RC.
printf '#!/bin/sh\n[ "$1" = --help ] || exit 9\nprintf "%%b" "$PASTA_HELP"\nexit "${PASTA_RC:-0}"\n' > "$WORK/bin/pasta"
chmod +x "$WORK/bin/pasta"
PASTA_HELP='Usage: pasta [OPTION]...\n  --map-host-loopback ADDR\n  --map-guest-addr ADDR\tTranslate ADDR to the host\n' run pasta-option
check "a pasta that lists --map-guest-addr passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
PASTA_HELP='Usage: pasta [OPTION]...\n  --map-host-loopback ADDR\n  --map-gw\n' run pasta-option
check "the pasta of an older passt, without it, is refused and the option named" "1 1" "$rc $(said 'pasta lacks --map-guest-addr, which Podman passes')"
PASTA_HELP='Usage: pasta\n  --map-guest-addr ADDR\n' PASTA_RC=1 run pasta-option
check "a pasta that lists it and exits non-zero passes: the text is the verdict, not the status" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
PASTA_HELP='Usage: pasta\n  --map-gw\n' PASTA_RC=1 run pasta-option
check "one that does not list it is refused whatever its status" "1 1" "$rc $(said 'pasta lacks --map-guest-addr, which Podman passes')"
PASTA_HELP='' PASTA_RC=127 run pasta-option
check "a pasta that prints nothing is refused for that, not for the option" "1 1 0" \
	"$rc $(said 'pasta --help printed nothing') $(said 'pasta lacks --map-guest-addr, which Podman passes')"

# --- two containers find each other by name ----------------------------------------
# A podman that records each call and answers the name lookup with $HOSTS. Starting
# the first container fails when START_FAILS is set, the lookup when LOOKUP_FAILS is.
cat > "$WORK/bin/podman" <<'PODMAN'
#!/usr/bin/env bash
echo "$*" >> "$PODMAN_LOG"
case " $* " in
	*" run -d "*) [ -z "${START_FAILS:-}" ] || exit 125 ;;
	*"/getent hosts "*) [ -z "${LOOKUP_FAILS:-}" ] || exit 2; printf '%b' "${HOSTS:-}" ;;
esac
PODMAN
chmod +x "$WORK/bin/podman"
dns() { : > "$WORK/podman.log"; PODMAN_LOG="$WORK/podman.log" run dns smoke /root-dir; }
asked() { grep -c -x -F -- "$1" "$WORK/podman.log"; }
HOSTS='10.89.0.2       smoke-a\n' dns
check "a name that resolves passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
check "it starts a container by name on the network, asks a second one for that name, then removes the first" "1 1 1" \
	"$(asked '--storage-driver vfs run -d --name smoke-a --network smoke --rootfs /root-dir /usr/bin/sleep 120') $(asked '--storage-driver vfs run --rm --network smoke --rootfs /root-dir /usr/bin/getent hosts smoke-a') $(sed -n 3p "$WORK/podman.log" | grep -c -x -F -- '--storage-driver vfs rm -f smoke-a')"
HOSTS='' dns
check "a name that does not resolve is refused" "1 1" "$rc $(said 'a container on the bridge network could not resolve another by name')"
check "and the first container is removed all the same" 1 "$(asked '--storage-driver vfs rm -f smoke-a')"
LOOKUP_FAILS=1 HOSTS='' dns
check "a lookup that fails is refused for the same reason" "1 1" "$rc $(said 'a container on the bridge network could not resolve another by name')"
START_FAILS=1 HOSTS='10.89.0.2 smoke-a\n' dns
check "a first container that does not start is refused for that, and no lookup is made" "1 1 0" \
	"$rc $(said 'could not start a container on the network smoke') $(grep -c 'getent' "$WORK/podman.log")"

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
run pasta-option extra
check "pasta-option with an argument is a usage error" 2 "$rc"
run dns smoke
check "dns without a root directory is a usage error" 2 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
