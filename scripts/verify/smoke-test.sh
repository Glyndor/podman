#!/usr/bin/env bash
#
# Install a freshly built podman .deb on a clean Debian or Ubuntu and prove it works before it
# is signed or published: right version, engine starts, a container runs.
# Run as root inside a clean container started with --privileged. The same
# package is tried on Debian 13 and Ubuntu 24.04 and 26.04.
#
# Usage: smoke-test.sh <deb> <version>

set -euo pipefail

deb="${1:?deb}"
version="${2:?version}"
[ -f "$deb" ] || { echo "no such file: $deb" >&2; exit 2; }

apt-get update -qq
apt-get install -y -qq --no-install-recommends "$deb"

got="$(podman --version)"
[ "$got" = "podman version $version" ] || { echo "version mismatch: $got" >&2; exit 1; }

podman --storage-driver vfs info >/dev/null

# The network stack must be the one shipped in the package, not Debian's.
for helper in netavark aardvark-dns; do
	[ -x "/usr/libexec/podman/$helper" ] || { echo "missing $helper in the package" >&2; exit 1; }
	"/usr/libexec/podman/$helper" --version
done

# A CI container has no pids cgroup controller to hand out, so crun refuses the
# default limit ("controller `pids` is not available"). runc, which Ubuntu 24.04
# uses, rejects --cgroups=disabled, so the limit is the thing turned off.
# --rootfs runs a directory as the container, so the test needs no registry.
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
cp -a /bin /lib /usr "$root/"
# amd64 keeps its dynamic loader under /lib64; arm64 has no such directory.
[ ! -e /lib64 ] || cp -a /lib64 "$root/"
out="$(podman --storage-driver vfs run --rm --pids-limit=0 --network none --rootfs "$root" /usr/bin/echo smoke-ok)"
[ "$out" = smoke-ok ] || { echo "container did not run: $out" >&2; exit 1; }
# A user-defined network goes through netavark, whose version Debian 13 pins
# older than the one Podman 6 expects, so this is the check that catches it.
podman --storage-driver vfs network create smoke >/dev/null
out="$(podman --storage-driver vfs run --rm --pids-limit=0 --network smoke --rootfs "$root" /usr/bin/echo net-ok)"
[ "$out" = net-ok ] || { echo "container did not run on a bridge network: $out" >&2; exit 1; }
echo "smoke test passed: podman $version"
