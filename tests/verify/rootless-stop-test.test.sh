#!/usr/bin/env bash
#
# Tests for scripts/verify/rootless-stop-test.sh. The body runs against stand-ins for the
# machine: podman, curl, busybox, pgrep, id, aa-enabled, dmesg, journalctl and sudo are
# fakes on PATH, so each check the script makes is seen to refuse what it exists to
# refuse, by what it says, next to a run where everything answers as a healthy package
# does. The pasta of the fake machine is a real `sleep` process: the script looks for a
# live process of that name, and the fake API ends it the way Podman's stop does.
#
# What a fake cannot show is the kernel: the denial itself, the profile of Podman and
# the profile of pasta. That is the step "Stop the last container of a bridge network
# through the API, on the runner" of .github/workflows/reusable-build.yml, which runs the
# script on the hosted runner of each architecture with the package just built.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/rootless-stop-test.sh"
WORK="$(mktemp -d)"
STATE="$WORK/state"
mkdir "$STATE"
cleanup() {
	[ ! -f "$STATE/pasta.pid" ] || kill "$(cat "$STATE/pasta.pid")" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

DENIED='audit: type=1400 audit(1.1:1): apparmor="DENIED" operation="signal" class="signal" profile="pasta" pid=1 comm="podman" requested_mask="receive" denied_mask="receive" signal=term peer="podman"'
OTHER='audit: type=1400 audit(1.1:2): apparmor="DENIED" operation="signal" class="signal" profile="other" pid=1 comm="podman" signal=term peer="podman"'

B="$WORK/bin"
mkdir "$B"
fake() { printf '#!/bin/sh\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
fake id 'echo "${FAKE_UID:-1000}"'
fake busybox 'exit 0'
fake aa-enabled 'echo Yes'
# pasta is alive while the file names a process that is, and not a zombie of one.
fake pgrep '[ -f "$STATE/pasta.pid" ] || exit 1
pid="$(cat "$STATE/pasta.pid")"
[ -d "/proc/$pid" ] && ! grep -q "^State:.*Z" "/proc/$pid/status" || exit 1
echo "$pid"'
fake podman 'echo "podman $*" >> "$CALLS"
start_pasta() { sleep 60 >/dev/null 2>&1 </dev/null & echo $! > "$STATE/pasta.pid"; }
case "$1 $2" in
	"ps -q") [ "$FAKE" != other-containers ] || echo 0a3c973d42c4; exit 0 ;;
	"network create"|"network rm"|"rm -f") exit 0 ;;
	"run -d")
		[ "$FAKE" != no-start ] || { echo "Error: crun failed" >&2; exit 125; }
		[ "$FAKE" = no-pasta ] || start_pasta
		: > "$STATE/running"; exit 0 ;;
	"system service") [ "$FAKE" != api-down ] || exit 1; echo $$ > "$STATE/service.pid"; exec sleep 60 ;;
	"inspect -f") [ "$3" = "{{.State.Running}}" ] || exit 9
		if [ -f "$STATE/running" ]; then echo true; else echo false; fi ;;
	*) exit 9 ;;
esac'
# The API: a ping answers, and the stop does what each case says. The code goes to stdout
# as -w asked, the body to the file -o names.
fake curl 'echo "curl $*" >> "$CALLS"
case "$*" in
	*_ping*) [ "$FAKE" != api-down ] || exit 7; exit 0 ;;
	*"/stop?"*) ;;
	*) exit 9 ;;
esac
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
stop_pasta() { [ ! -f "$STATE/pasta.pid" ] || kill "$(cat "$STATE/pasta.pid")" 2>/dev/null || true; }
code=204; : > "$out"
case "$FAKE" in
	curl-fails) printf "000"; exit 7 ;;
	stop-500)
		code=500; rm -f "$STATE/running"; stop_pasta
		echo "{\"cause\":\"permission denied\",\"message\":\"rootless netns: kill network process: permission denied\"}" > "$out" ;;
	still-running) stop_pasta ;;
	pasta-left) rm -f "$STATE/running" ;;
	*) rm -f "$STATE/running"; stop_pasta ;;
esac
printf "%s" "$code"'
# The kernel log, read three ways that each may be refused to an unprivileged user.
fake dmesg 'echo "dmesg" >> "$CALLS"; [ "$FAKE_KERNEL" = dmesg ] || exit 1; echo "$DENIED"'
fake journalctl 'echo "journalctl $*" >> "$CALLS"
case "$FAKE_KERNEL" in journal) echo "$DENIED" ;; other) echo "$OTHER" ;; *) exit 1 ;; esac'
fake sudo 'echo "sudo $*" >> "$CALLS"; [ "$1 $2" = "-n dmesg" ] || exit 9; [ "$FAKE_KERNEL" = sudo ] || exit 1; echo "$DENIED"'

run() { # [NAME=value ...]: sets $rc and $out; every case starts from a machine at rest
	rm -f "$STATE"/*; : > "$WORK/calls"; rm -rf "$WORK/tmp"; mkdir "$WORK/tmp"
	rc=0
	out="$(env PATH="$B:$PATH" CALLS="$WORK/calls" STATE="$STATE" TMPDIR="$WORK/tmp" DENIED="$DENIED" OTHER="$OTHER" \
		FAKE= FAKE_KERNEL= "$@" bash "$SCRIPT" 2>&1 </dev/null)" || rc=$?
}
said() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
called() { grep -c -E -- "$1" "$WORK/calls"; }

# --- the machine is not one the test can say anything on ----------------------------
run FAKE_UID=0
check "root is refused with 2, for being root" "2 1" "$rc $(said 'not as root')"
check "and nothing was touched" 0 "$(called '^podman')"

# A PATH with every tool the script uses except curl: the case is refused for curl and
# for nothing else, and the healthy run below has the same PATH with curl in it.
NOCURL="$WORK/nocurl"
mkdir "$NOCURL"
for t in id busybox aa-enabled pgrep podman dmesg journalctl sudo; do cp "$B/$t" "$NOCURL/$t"; done
for t in mktemp cp seq sleep tr grep tail date cat rm mkdir kill dirname; do ln -s "$(command -v "$t")" "$NOCURL/$t"; done
rm -f "$STATE"/*; : > "$WORK/calls"
rc=0; out="$(env PATH="$NOCURL" CALLS="$WORK/calls" STATE="$STATE" TMPDIR="$WORK/tmp" FAKE= FAKE_KERNEL= "$(command -v bash)" "$SCRIPT" 2>&1 </dev/null)" || rc=$?
check "a machine without curl: refused with 2, for curl" "2 1" "$rc $(said 'curl is needed and is not installed')"
check "and nothing was touched" 0 "$(called '^podman')"

run FAKE=other-containers
check "another container running: refused with 2, and it names it" "2 1 1" \
	"$rc $(said 'this user has running containers') $(said '0a3c973d42c4')"
check "and no network was created" 0 "$(called '^podman network create')"

rm -f "$STATE"/*; sleep 60 >/dev/null 2>&1 & echo $! > "$STATE/pasta.pid"
: > "$WORK/calls"; rc=0
out="$(env PATH="$B:$PATH" CALLS="$WORK/calls" STATE="$STATE" TMPDIR="$WORK/tmp" FAKE= FAKE_KERNEL= bash "$SCRIPT" 2>&1 </dev/null)" || rc=$?
check "a pasta that was already there: refused with 2, and it names it" "2 1 1" \
	"$rc $(said 'already has a pasta process') $(said "$(cat "$STATE/pasta.pid")")"
check "and no network was created" 0 "$(called '^podman network create')"
kill "$(cat "$STATE/pasta.pid")" 2>/dev/null || true

# --- a healthy package --------------------------------------------------------------
run
check "a healthy package: passes, and says what it proved" "0 1" "$rc $(said 'rootless stop test passed: the last container of a bridge network stopped through the API (204)')"
check "and it says what AppArmor is doing, as information" 1 "$(said 'AppArmor: Yes')"
check "and the network was created first, under a name of this run" 1 "$(called '^podman network create aa-pasta-net-[0-9]+$')"
check "and the container went on a network of its own, in the background" 1 \
	"$(called '^podman run -d --name aa-pasta-ctr-[0-9]+ --network aa-pasta-net-[0-9]+ --rootfs ')"
check "and the stop was a POST to the container's stop route, on the socket in the work directory" 1 \
	"$(called 'curl .*-X POST --unix-socket '"$WORK"'/tmp/tmp[.][^/]+/podman[.]sock http://d/v5[.]0[.]0/libpod/containers/aa-pasta-ctr-[0-9]+/stop[?]timeout=1')"
check "and the API was served by podman system service with no timeout, on that socket" 1 \
	"$(called '^podman system service --time=0 unix://'"$WORK"'/tmp/tmp[.][^/]+/podman[.]sock$')"
check "and the container and the network were removed afterwards" "1 1" \
	"$(called '^podman rm -f -t 0 aa-pasta-ctr-[0-9]+$') $(called '^podman network rm -f aa-pasta-net-[0-9]+$')"
# The API process ends with the script: it is a process of the machine, not of the test.
pid="$(cat "$STATE/service.pid" 2>/dev/null || echo 0)"; alive=1
for _ in $(seq 1 50); do
	if [ ! -d "/proc/$pid" ] || grep -q '^State:.*Z' "/proc/$pid/status"; then alive=0; break; fi
	sleep 0.1
done
check "and the API process it started is ended" "yes 0" "$([ "$pid" != 0 ] && echo yes || echo no) $alive"
check "and the work directory is gone" 0 "$(find "$WORK/tmp" -mindepth 1 | wc -l)"

# --- what each failure says ---------------------------------------------------------
run FAKE=no-start
check "a container that does not start: refused, with what podman said" "1 1 1" \
	"$rc $(said 'a rootless container on a bridge network did not start') $(said 'crun failed')"
check "and the network is still removed" 1 "$(called '^podman network rm -f aa-pasta-net-')"
run FAKE=no-pasta
check "no pasta behind the namespace: refused, because the stop would not signal anything" "1 1 0" \
	"$rc $(said 'no pasta serves the rootless network namespace') $(said 'answered')"
run FAKE=api-down
check "an API that never answers: refused for the API, not for the stop" "1 1 0" \
	"$rc $(said 'the Podman API did not answer on ') $(said 'answered')"
check "and the container is still removed" 1 "$(called '^podman rm -f -t 0 aa-pasta-ctr-')"

run FAKE=stop-500 FAKE_KERNEL=journal
check "a stop that answers 500: refused, with the code and the body" "1 1 1" \
	"$rc $(said 'answered 500, not 204') $(said 'rootless netns: kill network process: permission denied')"
check "and it is refused for the answer only: the container is stopped and pasta is gone" "0 0" \
	"$(said 'still running after the stop') $(said 'pasta was still running')"
check "and the journal was asked for the kernel only, from when the run began" 1 \
	"$(called '^journalctl -k --no-pager --since [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}$')"
check "and the kernel line that names the denial is shown, read from the journal" "1 1" \
	"$(said 'the kernel refused the signal to pasta') $(said 'apparmor="DENIED" operation="signal" class="signal" profile="pasta"')"
check "and sudo was not asked for" 0 "$(called '^sudo')"
run FAKE=stop-500 FAKE_KERNEL=dmesg
check "the same line, read from dmesg when that is allowed" "1 1" \
	"$rc $(said 'apparmor="DENIED" operation="signal" class="signal" profile="pasta"')"
run FAKE=stop-500 FAKE_KERNEL=sudo
check "a log nobody but root reads, and no sudo asked for: the message says it could not read it" "1 1 0 0" \
	"$rc $(said 'no AppArmor denial of a signal to pasta could be read') $(said 'profile="pasta"') $(called '^sudo')"
run FAKE=stop-500 FAKE_KERNEL=sudo ROOTLESS_STOP_TEST_SUDO=1
check "with ROOTLESS_STOP_TEST_SUDO=1 it asks sudo -n dmesg, and shows the line" "1 1 1" \
	"$rc $(called '^sudo -n dmesg$') $(said 'apparmor="DENIED" operation="signal" class="signal" profile="pasta"')"
run FAKE=stop-500 FAKE_KERNEL=other
check "a denial for another profile is not the one: the message says none was read" "1 1 0" \
	"$rc $(said 'no AppArmor denial of a signal to pasta could be read') $(said 'profile="other"')"

run FAKE=curl-fails
check "a stop whose request never got an answer: refused as that, not read as a code" "1 1 0" \
	"$rc $(said 'answered curl failed, not 204') $(said 'answered 000')"
run FAKE=still-running
check "a container still running after a 204: refused for that and only that" "1 1 0 0" \
	"$rc $(said 'the container is still running after the stop (running: true)') $(said 'answered') $(said 'pasta was still running')"
run FAKE=pasta-left
check "a pasta still running after a 204: refused for that, and it names the process" "1 1 0 0" \
	"$rc $(said 'pasta was still running after the stop: ') $(said 'answered') $(said 'still running after the stop (running')"
# The kill is a signal: give the process a moment to be gone, then read it again.
pid="$(cat "$STATE/pasta.pid")"; alive=1
for _ in $(seq 1 50); do
	if [ ! -d "/proc/$pid" ] || grep -q '^State:.*Z' "/proc/$pid/status"; then alive=0; break; fi
	sleep 0.1
done
check "and the pasta it left is ended by the cleanup" 0 "$alive"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
