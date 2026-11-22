#!/usr/bin/env bash
#
# Stop the last container of a bridge network through the API, as the unprivileged user
# that called the script, and require that it works.
#
# When a rootless bridge network loses its last container, Podman shuts the rootless
# network namespace down and sends SIGTERM to the pasta that serves it. On Ubuntu the
# apparmor package confines /usr/bin/podman under a profile named `podman`, and the
# profile of pasta has to admit a signal from that peer, or the kernel answers
#   apparmor="DENIED" operation="signal" profile="pasta" comm="podman" signal=term peer="podman"
# and Podman reports 500 "rootless netns: kill network process: permission denied" to
# the caller of POST /containers/<id>/stop. `podman stop` on the command line reaches the
# same code and fails the same way (status 125, "removing container <id> network: ...").
#
# The stop goes through the API, on a socket of its own inside the work directory,
# because that is what the clients of libpod call and because the HTTP code is a verdict
# that needs no parsing: 204 or not.
# Only the last container of the network shows it: with another one alive the namespace
# stays up and nothing is signalled, so this refuses to run next to other containers or
# another pasta of the same user. A run that cannot reach the code it checks would pass
# whatever the package holds.
#
# It does not install anything: podman, curl, busybox and aa-enabled come from the machine.
# The rule it exists to check is only exercised where AppArmor is on and the Podman it
# starts runs under the `podman` profile. On any other machine the stop would pass with
# or without the rule, so there the script stops with status 2 and says so: a green that
# never looked is not a result.
#
# The kernel line that names the denial is read with dmesg, then journalctl -k, and then
# with `sudo -n dmesg` only when ROOTLESS_STOP_TEST_SUDO is set to 1, which is the case
# of a throwaway runner. The line only enriches the message: the verdict is the answer
# of the API.
#
# Usage: rootless-stop-test.sh

set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "run this as an unprivileged user, not as root" >&2; exit 2; }
for tool in podman curl busybox pgrep aa-enabled; do
	command -v "$tool" >/dev/null 2>&1 || { echo "$tool is needed and is not installed" >&2; exit 2; }
done
uid="$(id -u)"

# What is running now decides whether the stop below can shut the namespace down.
others="$(podman ps -q)"
[ -z "$others" ] || { echo "this user has running containers, so the network namespace would stay up and the stop proves nothing: $others" >&2; exit 2; }
pasta_pids() { pgrep -u "$uid" '^pasta' || true; }
[ -z "$(pasta_pids)" ] || { echo "this user already has a pasta process, so one left after the stop would prove nothing: $(pasta_pids | tr '\n' ' ')" >&2; exit 2; }

aa="$(aa-enabled 2>&1 || true)"
[ "$aa" = Yes ] || { echo "AppArmor is not enabled on this machine (aa-enabled says: $aa), so the stop proves nothing about its profiles" >&2; exit 2; }
echo "AppArmor: $aa"

work="$(mktemp -d)"
net="aa-pasta-net-$$"
ctr="aa-pasta-ctr-$$"
sock="$work/podman.sock"
service=""
cleanup() {
	[ -z "$service" ] || kill "$service" 2>/dev/null || true
	podman rm -f -t 0 "$ctr" >/dev/null 2>&1 || true
	podman network rm -f "$net" >/dev/null 2>&1 || true
	# A pasta the stop did not end belongs to this run: nothing else of this user had one.
	for p in $(pasta_pids); do kill "$p" 2>/dev/null || true; done
	rm -rf "$work"
}
trap cleanup EXIT

# What decides the network backend and its firewall driver on this machine, for the
# message of a container that did not start: netavark refuses a driver it was not built
# with, and the name it is given comes from the environment or from a containers.conf.
network_settings() {
	echo "network backend: $(podman info --format '{{.Host.NetworkBackend}} {{.Host.NetworkBackendInfo.Version}}' 2>&1 || true)"
	echo "environment: $(env | grep -E '^(NETAVARK|CONTAINERS)_' | tr '\n' ' ' || true)"
	# grep answers non-zero when one of the folders is missing, whatever it found.
	echo "firewall_driver and network_backend lines in containers.conf: $(grep -rsn -E \
		'^[[:space:]]*(firewall_driver|network_backend)[[:space:]]*=' \
		/usr/share/containers /etc/containers "${XDG_CONFIG_HOME:-$HOME/.config}/containers" | tr '\n' ' ' || true)"
}

# The same one-binary container rootless-test.sh runs.
root="$work/root"
mkdir -p "$root/bin" "$root/etc" "$root/proc" "$root/sys" "$root/dev" "$root/tmp"
cp "$(command -v busybox)" "$root/bin/busybox"

started="$(date '+%Y-%m-%d %H:%M:%S')"
podman network create "$net" >/dev/null
podman run -d --name "$ctr" --network "$net" --rootfs "$root" /bin/busybox sleep 300 >/dev/null \
	|| { echo "a rootless container on a bridge network did not start" >&2; network_settings >&2; exit 1; }
[ -n "$(pasta_pids)" ] \
	|| { echo "no pasta serves the rootless network namespace, so the stop would not signal anything" >&2; exit 1; }

podman system service --time=0 "unix://$sock" </dev/null >"$work/service.log" 2>&1 &
service=$!
ready=""
for _ in $(seq 1 100); do
	if curl -s -o /dev/null --unix-socket "$sock" http://d/libpod/_ping; then
		ready=1
		break
	fi
	kill -0 "$service" 2>/dev/null || break
	sleep 0.1
done
[ -n "$ready" ] || { echo "the Podman API did not answer on $sock: $(cat "$work/service.log")" >&2; exit 1; }
profile="$(cat "/proc/$service/attr/current" 2>/dev/null || echo unknown)"
case "$profile" in
	podman | "podman ("*) echo "Podman API runs under AppArmor profile: $profile" ;;
	*) echo "podman system service runs under the AppArmor profile '$profile', not under podman, so on this machine the signal to pasta never comes from the peer the rule admits and the stop proves nothing" >&2; exit 2 ;;
esac

# The libpod routes of a container exist only under a version prefix; any version the
# server supports reaches the same handler, so one that every Podman since 5.0 accepts.
code="$(curl -s -o "$work/stop.body" -w '%{http_code}' -X POST --unix-socket "$sock" \
	"http://d/v5.0.0/libpod/containers/$ctr/stop?timeout=1")" || code="curl failed"

# pasta leaves when it is told to, not at the instant the stop returns.
for _ in $(seq 1 100); do
	[ -n "$(pasta_pids)" ] || break
	sleep 0.1
done
left="$(pasta_pids | tr '\n' ' ')"
running="$(podman inspect -f '{{.State.Running}}' "$ctr" 2>&1 || true)"

kernel_log() {
	{ dmesg 2>/dev/null \
		|| journalctl -k --no-pager --since "$started" 2>/dev/null \
		|| { [ "${ROOTLESS_STOP_TEST_SUDO:-}" != 1 ] || sudo -n dmesg 2>/dev/null; }; } \
		| grep -E 'apparmor="DENIED".*operation="signal".*profile="[^"]*pasta' | tail -n 3 || true
}

problems=0
if [ "$code" != 204 ]; then
	problems=1
	echo "stopping the last container of a bridge network through the API answered $code, not 204: $(cat "$work/stop.body")" >&2
	denied="$(kernel_log)"
	if [ -n "$denied" ]; then
		echo "the kernel refused the signal to pasta:" >&2
		printf '%s\n' "$denied" >&2
	else
		echo "no AppArmor denial of a signal to pasta could be read from the kernel log" >&2
	fi
fi
if [ "$running" != false ]; then
	problems=1
	echo "the container is still running after the stop (running: $running)" >&2
fi
if [ -n "$left" ]; then
	problems=1
	echo "pasta was still running after the stop: $left" >&2
fi
[ "$problems" -eq 0 ] || exit 1

echo "rootless stop test passed: the last container of a bridge network stopped through the API (204), the container is stopped and pasta is gone"
