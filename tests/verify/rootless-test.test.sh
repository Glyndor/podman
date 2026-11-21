#!/usr/bin/env bash
#
# Tests for scripts/verify/rootless-test.sh. The argument contract runs as it is. The
# body runs against stand-ins for the machine: sudo, apt-get, id, dpkg, podman, pasta,
# busybox and python3 (the listener and its probe) are fakes on PATH, so each check the
# script makes is seen to refuse what it exists to refuse, by what it says, next to a
# run where everything answers as a healthy package does.
#
# What a fake cannot show is a real rootless container: packets through pasta, the
# address --map-guest-addr maps, the kernel and AppArmor of a real machine. That is
# the step "Run a rootless container on pasta, on the runner itself" of
# .github/workflows/reusable-build.yml, which runs this script on the hosted runner of
# each architecture.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/rootless-test.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

if "$SCRIPT" >/dev/null 2>&1; then rc=0; else rc=1; fi; check "no arguments fails" 1 "$rc"
"$SCRIPT" /nonexistent.deb 6.2.0 >/dev/null 2>&1; check "missing deb fails with 2" 2 "$?"

# As root it must stop before it touches the machine: the point of the script is an
# unprivileged user. A stand-in `id` says 0; the deb exists so that is not what stops it.
mkdir "$WORK/root-id"
printf '#!/bin/sh\necho 0\n' > "$WORK/root-id/id"; chmod +x "$WORK/root-id/id"
: > "$WORK/x.deb"
out="$(PATH="$WORK/root-id:$PATH" "$SCRIPT" "$WORK/x.deb" 6.2.0 2>&1)"; rc=$?
check "root is refused with 2" 2 "$rc"
check "root is refused for being root" 1 "$(printf '%s\n' "$out" | grep -c 'not as root')"

# --- the body, against a machine of fakes -------------------------------------------
# $FAKE names the one thing that goes wrong; every other answer is a healthy package's.
B="$WORK/bin"
mkdir "$B"
fake() { printf '#!/bin/sh\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
fake id 'echo 1000'
fake sudo 'exec env "$@"'
fake apt-get 'echo "apt-get $*" >> "$CALLS"'
fake pasta 'exit 0'
fake busybox 'exit 0'
fake dpkg '[ "$1" = -S ] || exit 9
case "$FAKE" in foreign-pasta) echo "passt: $2" ;; *) echo "podman: $2" ;; esac'
# The listener: a process that stays until the script kills it, or one that died.
# The probe answers whether it is up. Neither touches the network.
fake python3 'case "$1 $2" in
	"-m http.server") [ "$FAKE" != listener-dead ] || exit 1; exec sleep 60 ;;
	"-c "*) [ "$FAKE" != listener-dead ] ;;
	*) exit 9 ;;
esac'
# podman answers --version, the container that echoes, and the one that fetches the
# probe through pasta: it reads the file the script served, beside the rootfs.
fake podman 'echo "podman $*" >> "$CALLS"
[ "$1" = --version ] && { echo "podman version ${FAKE_VERSION:-6.2.0}"; exit 0; }
rootfs=""; prev=""
for a in "$@"; do [ "$prev" = --rootfs ] && rootfs="$a"; prev="$a"; done
case " $* " in
	*" echo rootless-ok "*)
		case "$FAKE" in
			no-start) echo "Error: pasta failed to start" >&2; exit 125 ;;
			no-run) echo "something else" ;;
			*) echo "a warning about cgroups"; echo rootless-ok ;;
		esac ;;
	*" wget "*)
		case "$FAKE" in
			unreachable) echo "wget: bad address" >&2; exit 1 ;;
			wrong-answer) echo "<html>a proxy page</html>" ;;
			*) cat "${rootfs%/root}/srv/probe" ;;
		esac ;;
	*) exit 9 ;;
esac'

body() { # [FAKE=<what goes wrong>] [FAKE_VERSION=<what podman says>]: sets $rc and $out
	: > "$WORK/calls"
	rc=0
	out="$(env PATH="$B:$PATH" CALLS="$WORK/calls" FAKE= "$@" bash "$SCRIPT" "$WORK/x.deb" 6.2.0 2>&1)" || rc=$?
}
said() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

body
check "a healthy package: passes, and says what it ran on" "0 1" "$rc $(said 'rootless test passed: podman 6.2.0 on ')"
check "and it installed the package it was given, with busybox-static" 1 \
	"$(grep -c -x -F "apt-get install -y -qq $(realpath "$WORK/x.deb") busybox-static" "$WORK/calls")"
check "and both containers ran on pasta" 2 "$(grep -c '^podman run --rm --network pasta --rootfs ' "$WORK/calls")"
check "and the second one fetched the probe from the host" 1 \
	"$(grep -c -F 'wget -q -T 20 -O - http://host.containers.internal:18473/probe' "$WORK/calls")"

body FAKE_VERSION=6.1.0
check "a podman that is not the version built: refused, and it says which" "1 1" "$rc $(said 'version mismatch: podman version 6.1.0')"
body FAKE=foreign-pasta
check "a pasta that dpkg says another package owns: refused" "1 1" "$rc $(said 'pasta on this machine does not come from the package')"
check "and no container is run with it" 0 "$(grep -c '^podman run' "$WORK/calls")"
body FAKE=no-start
check "a container that does not start on pasta: refused, with what podman said" "1 1 1" \
	"$rc $(said 'a rootless container on pasta did not start') $(said 'pasta failed to start')"
body FAKE=no-run
check "a container that starts and does not print what it was told: refused" "1 1" "$rc $(said 'a rootless container on pasta did not run: something else')"
body FAKE=listener-dead
check "a listener that never came up: refused for the listener, not for the network" "1 1 0" \
	"$rc $(said 'the listener for the network check did not come up on port 18473') $(said 'could not reach the host')"
body FAKE=unreachable
check "a container that cannot reach the host: refused, with what wget said" "1 1 1" \
	"$rc $(said 'a rootless container could not reach the host through pasta') $(said 'wget: bad address')"
body FAKE=wrong-answer
check "an answer that is not the probe's: refused" "1 1" "$rc $(said 'the answer through pasta was not the expected one: <html>a proxy page</html>')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
