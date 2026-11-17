#!/usr/bin/env bash
#
# Install a freshly built podman .deb on Debian 13 and prove it works before it
# is signed or published: right version, engine starts, a container runs.
# Run as root inside a debian:13 container started with --privileged.
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

# --rootfs runs a directory as the container, so the test needs no registry.
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{bin,lib,lib64,usr}
cp -a /bin/. "$root/bin/" 2>/dev/null || true
cp -a /lib/. "$root/lib/" 2>/dev/null || true
cp -a /usr/. "$root/usr/" 2>/dev/null || true
out="$(podman --storage-driver vfs run --rm --network none --rootfs "$root" /bin/echo smoke-ok)"
[ "$out" = smoke-ok ] || { echo "container did not run: $out" >&2; exit 1; }
echo "smoke test passed: podman $version"
