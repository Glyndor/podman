#!/usr/bin/env bash
#
# Tests for scripts/package/verify/runtime-checks.sh as far as a stand-in reaches. It is the part
# of the proof of a native package that starts containers, which needs a machine of the
# distribution with the package installed; its real run is the one of rpm-test.sh and
# pacman-test.sh in the workflow. What is held here is that it parses, that it is sourced and not
# run, and that the checks of the proof are all still in it by name.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$HERE/scripts/package/verify/runtime-checks.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

bash -n "$LIB"; check "the file parses" 0 "$?"
for name in \
	"a container runs as root" \
	"a container resolves another by name on a bridge network (netavark and aardvark-dns), root" \
	"an unprivileged user can map ids and Podman can create its namespace" \
	"a container runs on pasta, rootless" \
	"a rootless container reaches the host through pasta" \
	"a rootless container resolves another by name on a bridge network" \
	"the last container of a rootless bridge network stops through the API" \
	"no pasta is left running after the last container stopped, waited for ten seconds at most"; do
	check "the check '$name' is there" 1 "$(grep -c -F -- "\"$name\"" "$LIB")"
done
check "it defines nothing that runs on its own: no exit of its own" 0 "$(grep -c '^exit' "$LIB")"
for user in rpm-test pacman-test; do
	file="$HERE/scripts/package/verify/$user.sh"
	[ -f "$file" ] || continue
	check "$user.sh sources it" 1 "$(grep -c '^\. "\$here/runtime-checks.sh"' "$file")"
done

# --- the wait for the last pasta, run with a clock the test moves: it says how long it really waited ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sed -n '/^pasta_gone() {/,/^}/p' "$LIB" > "$WORK/pasta_gone.sh"
check "the function of the wait is found in the lib" 1 "$(grep -c '^pasta_gone() {' "$WORK/pasta_gone.sh")"
# A sleep that only moves the clock, and a date that reads it, so ten seconds take no time and the numbers are exact.
run_wait() { # <polls before the pasta goes: 0 none, 99 never> -> its output and exit status
	(
		clock=0; polls=0; keep="$1"; real=
		date() { echo "$clock"; }
		sleep() { clock=$((clock + 200000000)); polls=$((polls + 1)); }
		pasta_pids() { if [ "$keep" -ne 0 ] && [ "$polls" -lt "$keep" ]; then echo "$real"; fi; }
		rl() { echo "state of the user: $*"; }
		command sleep 60 &
		real=$!
		# shellcheck disable=SC1091
		. "$WORK/pasta_gone.sh"
		pasta_gone; rc=$?
		kill "$real" 2> /dev/null
		echo "rc=$rc"
	) 2>&1
}
out="$(run_wait 0)"
check "with no pasta left it says so, and that it waited nothing" "no pasta was left after waiting 0.000 s rc=0" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
out="$(run_wait 3)"
check "with a pasta that goes after three polls it says it waited 0.600 s" "no pasta was left after waiting 0.600 s rc=0" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
out="$(run_wait 99)"
check "with a pasta that stays it says it waited the ten seconds and fails" "1 1" "$(printf '%s\n' "$out" | grep -c 'rc=1') $(printf '%s\n' "$out" | grep -c 'pasta is still running after waiting 10.000 s, the whole ten seconds')"
check "and it shows the command line of the process" 1 "$(printf '%s\n' "$out" | grep -c 'sleep 60')"
check "and its parent" 1 "$(printf '%s\n' "$out" | grep -c '^  parent: ')"
check "and its network namespace and the containers of the user" "1 1" "$(printf '%s\n' "$out" | grep -c '^  network namespace ') $(printf '%s\n' "$out" | grep -c '^state of the user: state')"

# --- the wait for the listener of the host-side check: read from the sockets, never by a connection ---
grep -m1 '^	listener_up() {' "$LIB" | sed 's/^[[:space:]]*//' > "$WORK/listener_up.sh"
check "the function that asks whether the listener is up is found in the lib" 1 "$(grep -c '^listener_up() {' "$WORK/listener_up.sh")"
# A real server on port 18473, on :: (both families) or on IPv4 only, that counts the connections it is given.
serve() { # <family: v6|v4> <seconds>: listens, counts connections in $WORK/accepted
	python3 - "$1" "$2" "$WORK/accepted" <<'PY' &
import socket, sys, time
fam, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET6 if fam == "v6" else socket.AF_INET)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if fam == "v6":
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    s.bind(("::", 18473))
else:
    s.bind(("0.0.0.0", 18473))
s.listen(5)
s.settimeout(0.1)
n, end = 0, time.time() + secs
while time.time() < end:
    try:
        c, _ = s.accept()
        c.close()
        n += 1
        open(out, "w").write(str(n))
    except socket.timeout:
        pass
PY
	serve_pid=$!
	for _ in $(seq 1 50); do
		awk '$4 == "0A" && $2 ~ /:4829$/ { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2> /dev/null && return
		sleep 0.1
	done
}
# shellcheck disable=SC1091
. "$WORK/listener_up.sh"
if awk '$4 == "0A" && $2 ~ /:4829$/ { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2> /dev/null; then
	echo "FAIL  port 18473 is already in use on this machine, so the listener cannot be tried"; fail=$((fail + 1))
else
	check "with nothing listening on 18473 it says no" 1 "$(listener_up; echo $?)"
	rm -f "$WORK/accepted"
	serve v6 4
	check "with a server on :: it says yes" 0 "$(listener_up; echo $?)"
	check "and asking again changes nothing" 0 "$(listener_up; echo $?)"
	check "and no connection was made to the server" "" "$(cat "$WORK/accepted" 2> /dev/null)"
	kill "$serve_pid" 2> /dev/null; wait "$serve_pid" 2> /dev/null
	serve v4 4
	check "with a server on IPv4 only it says yes" 0 "$(listener_up; echo $?)"
	kill "$serve_pid" 2> /dev/null; wait "$serve_pid" 2> /dev/null
	check "when the server is gone it says no" 1 "$(listener_up; echo $?)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
