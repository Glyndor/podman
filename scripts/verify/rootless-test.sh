#!/usr/bin/env bash
#
# Install the package on this machine and run a rootless container on pasta as the
# unprivileged user that called the script.
#
# smoke-test.sh runs as root inside a privileged container. An unprivileged user in
# there cannot map ids, so that script has to skip rootless networking, which is the
# one thing passt is in the package for. A hosted runner is an Ubuntu virtual machine
# with its own kernel, AppArmor and an ordinary user: what a customer's server is.
#
# It installs the package over whatever Podman the machine has, so it belongs on a
# machine that is thrown away afterwards. It never skips: a machine where a rootless
# container cannot run is a failure here, because nothing else would say so.
#
# Usage: rootless-test.sh <deb> <version>

set -euo pipefail

deb="${1:?deb}"
version="${2:?version}"
[ -f "$deb" ] || { echo "no such file: $deb" >&2; exit 2; }
[ "$(id -u)" -ne 0 ] || { echo "run this as an unprivileged user that has sudo, not as root" >&2; exit 2; }

sudo apt-get update -qq
# busybox-static is the whole container: one static binary, so the test needs no
# registry and does not copy this machine's /usr.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$(realpath "$deb")" busybox-static >/dev/null

got="$(podman --version)"
[ "$got" = "podman version $version" ] || { echo "version mismatch: $got" >&2; exit 1; }
# The pasta that runs has to be the one in the package, not one the machine already had.
dpkg -S "$(command -v pasta)" 2>/dev/null | grep -q '^podman:' \
	|| { echo "pasta on this machine does not come from the package" >&2; exit 1; }

work="$(mktemp -d)"
server=""
cleanup() {
	[ -z "$server" ] || kill "$server" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

root="$work/root"
mkdir -p "$root/bin" "$root/etc" "$root/proc" "$root/sys" "$root/dev" "$root/tmp"
cp "$(command -v busybox)" "$root/bin/busybox"

out="$(podman run --rm --network pasta --rootfs "$root" /bin/busybox echo rootless-ok 2>&1)" \
	|| { echo "a rootless container on pasta did not start: $out" >&2; exit 1; }
case "$out" in
	*rootless-ok) ;;
	*) echo "a rootless container on pasta did not run: $out" >&2; exit 1 ;;
esac

# Packets, not only a namespace. A listener on this machine is fetched from inside the
# container through host.containers.internal, the address Podman maps to the host with
# --map-guest-addr, which is the option an older pasta does not have.
mkdir -p "$work/srv"
echo pasta-ok > "$work/srv/probe"
port=18473
python3 -m http.server "$port" --bind 0.0.0.0 --directory "$work/srv" >/dev/null 2>&1 &
server=$!
ready=""
for _ in $(seq 1 50); do
	if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(s.connect_ex(('127.0.0.1', $port)))" 2>/dev/null; then
		ready=1
		break
	fi
	kill -0 "$server" 2>/dev/null || break
done
[ -n "$ready" ] || { echo "the listener for the network check did not come up on port $port" >&2; exit 1; }

got="$(podman run --rm --network pasta --rootfs "$root" \
	/bin/busybox wget -q -T 20 -O - "http://host.containers.internal:$port/probe" 2>&1)" \
	|| { echo "a rootless container could not reach the host through pasta: $got" >&2; exit 1; }
[ "$got" = pasta-ok ] || { echo "the answer through pasta was not the expected one: $got" >&2; exit 1; }

echo "rootless test passed: podman $version on $(. /etc/os-release && echo "$PRETTY_NAME"), $(uname -m)"
