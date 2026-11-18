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
# A customer who already runs the distribution's Podman, with the tools that depend on
# its containers-common, upgrades onto this package: that is the path to prove, not only
# an install on a clean image. buildah and skopeo have to stay.
apt-get install -y -qq podman buildah skopeo >/dev/null
# With the recommended packages, as a customer's apt installs them: passt, uidmap,
# a container init and dbus-user-session come with it.
apt-get install -y -qq "$deb"

# What a customer expects to find, and what Debian's own package installs: if a
# change to the build stops shipping one of these, the package is still "working"
# and nobody would notice until somebody asked why tab completion was gone.
for f in /usr/bin/podman /usr/bin/podman-remote /usr/libexec/podman/quadlet /usr/libexec/podman/rootlessport \
	/usr/lib/systemd/system/podman.socket /usr/lib/systemd/user/podman.socket \
	/usr/lib/systemd/system-generators/podman-system-generator /usr/lib/systemd/user-generators/podman-user-generator \
	/usr/lib/tmpfiles.d/podman.conf \
	/usr/share/bash-completion/completions/podman /usr/share/zsh/site-functions/_podman /usr/share/fish/vendor_completions.d/podman.fish; do
	[ -e "$f" ] || { echo "the package does not ship $f" >&2; exit 1; }
done
# The man pages are asked of dpkg, not of the disk: the minimal Ubuntu images
# tell dpkg to leave /usr/share/man out, so the files are shipped and not there.
dpkg -L podman | grep -q '^/usr/share/man/man1/podman-run\.1' || { echo "the package does not ship the man pages" >&2; exit 1; }

# The containers-common configuration of this release, not the older one a distribution
# ships: the profile has the futex family, a pull has the policy it needs, and the
# distribution's package is not what satisfies the dependency.
grep -q '"futex_waitv"' /usr/share/containers/seccomp.json || { echo "the seccomp profile is not this release's" >&2; exit 1; }
for f in policy.json registries.conf containers.conf registries.conf.d/000-shortnames.conf; do
	[ -s "/usr/share/containers/$f" ] || { echo "the package does not ship /usr/share/containers/$f" >&2; exit 1; }
done
! dpkg-query -W -f='${Status}' golang-github-containers-common 2>/dev/null | grep -q 'ok installed' \
	|| { echo "the distribution's containers-common is installed next to this package" >&2; exit 1; }
for kept in buildah skopeo; do
	dpkg-query -W -f='${Status}' "$kept" 2>/dev/null | grep -q 'ok installed' \
		|| { echo "$kept was removed by the upgrade" >&2; exit 1; }
done
dpkg -s podman | grep -q '^Provides:.*golang-github-containers-common (= 0\.[6-9][0-9]' \
	|| { echo "the package does not provide containers-common" >&2; exit 1; }

got="$(podman --version)"
[ "$got" = "podman version $version" ] || { echo "version mismatch: $got" >&2; exit 1; }

podman --storage-driver vfs info >/dev/null

# The network stack must be the one shipped in the package, not Debian's.
for helper in netavark aardvark-dns; do
	[ -x "/usr/libexec/podman/$helper" ] || { echo "missing $helper in the package" >&2; exit 1; }
	"/usr/libexec/podman/$helper" --version
done

# A CI container owns its cgroup but passes no controllers down to children, so
# crun and runc fail with "controller `pids` is not available". Move this shell
# into a child cgroup and enable the controllers for the siblings, as the
# Docker-in-Docker entrypoint does. Best effort: where cgroups are not writable
# the containers below decide whether it mattered.
if [ -w /sys/fs/cgroup/cgroup.subtree_control ]; then
	mkdir -p /sys/fs/cgroup/smoke-init
	echo $$ > /sys/fs/cgroup/smoke-init/cgroup.procs 2>/dev/null || true
	for c in $(cat /sys/fs/cgroup/cgroup.controllers); do
		echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
	done
fi
# --rootfs runs a directory as the container, so the test needs no registry.
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
cp -a /bin /lib /usr "$root/"
# amd64 keeps its dynamic loader under /lib64; arm64 has no such directory.
[ ! -e /lib64 ] || cp -a /lib64 "$root/"
out="$(podman --storage-driver vfs run --rm --network none --rootfs "$root" /usr/bin/echo smoke-ok)"
[ "$out" = smoke-ok ] || { echo "container did not run: $out" >&2; exit 1; }
# A user-defined network goes through netavark, whose version Debian 13 pins
# older than the one Podman 6 expects, so this is the check that catches it.
podman --storage-driver vfs network create smoke >/dev/null
out="$(podman --storage-driver vfs run --rm --network smoke --rootfs "$root" /usr/bin/echo net-ok)"
[ "$out" = net-ok ] || { echo "container did not run on a bridge network: $out" >&2; exit 1; }
# Two containers on that network have to find each other by name. That is
# aardvark-dns, the part of the network stack a single container cannot show:
# the bridge can be up and name resolution still broken.
podman --storage-driver vfs run -d --name smoke-a --network smoke --rootfs "$root" /usr/bin/sleep 120 >/dev/null
found="$(podman --storage-driver vfs run --rm --network smoke --rootfs "$root" /usr/bin/getent hosts smoke-a || true)"
podman --storage-driver vfs rm -f smoke-a >/dev/null 2>&1 || true
[ -n "$found" ] || { echo "a container on the bridge network could not resolve another by name" >&2; exit 1; }
echo "smoke test passed: podman $version"
