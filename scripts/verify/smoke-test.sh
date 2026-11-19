#!/usr/bin/env bash
#
# Install a freshly built podman .deb on a clean Debian or Ubuntu and prove it works before it
# is signed or published: right version, engine starts, a container runs.
# Run as root inside a clean container started with --privileged. The same
# package is tried on Debian 13 and Ubuntu 24.04 and 26.04.
#
# Usage: smoke-test.sh <deb> <version> [clean]
#   clean: install the package on the image as it is, without the distribution's Podman first.

set -euo pipefail

deb="${1:?deb}"
version="${2:?version}"
mode="${3:-upgrade}"
[ -f "$deb" ] || { echo "no such file: $deb" >&2; exit 2; }

apt-get update -qq
# A customer who already runs the distribution's Podman, with the tools that depend on
# its containers-common, upgrades onto this package: that is the path to prove, not only
# an install on a clean image. buildah and skopeo have to stay.
if [ "$mode" = clean ]; then :; else apt-get install -y -qq podman buildah skopeo podman-remote >/dev/null; fi
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
[ -s /etc/containers/policy.json ] || { echo "the package does not ship /etc/containers/policy.json" >&2; exit 1; }
for f in registries.conf containers.conf registries.conf.d/000-shortnames.conf; do
	[ -s "/usr/share/containers/$f" ] || { echo "the package does not ship /usr/share/containers/$f" >&2; exit 1; }
done
! dpkg-query -W -f='${Status}' golang-github-containers-common 2>/dev/null | grep -q 'ok installed' \
	|| { echo "the distribution's containers-common is installed next to this package" >&2; exit 1; }
# On a clean image the tools are installed after the package, as a customer who adds
# them later does; they must find their policy and registries under /etc/containers.
[ "$mode" != clean ] || apt-get install -y -qq buildah skopeo >/dev/null
# passt comes with the package: Podman 6.2.0 always passes pasta --map-guest-addr, which the
# passt of Ubuntu 24.04 (and of the other releases) predates, and the distribution's package is replaced.
! dpkg-query -W -f='${Status}' passt 2>/dev/null | grep -q 'ok installed' \
	|| { echo "the distribution's passt is installed next to this package" >&2; exit 1; }
dpkg -L podman | grep -q '^/usr/bin/pasta$' || { echo "the package does not ship pasta" >&2; exit 1; }
pasta --help 2>&1 | grep -q -- '--map-guest-addr' || { echo "pasta lacks --map-guest-addr, which Podman passes" >&2; exit 1; }
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
# skopeo and buildah read the policy from /etc/containers; a copy and a pull are what
# stop with "no policy.json file found" when it is not there.
img="$(mktemp -d)"
echo smoke > "$img/file"
tar -C "$img" -cf - file | podman --storage-driver vfs import - smoke-img >/dev/null
podman --storage-driver vfs save --format oci-dir -o "$img/oci" smoke-img
skopeo copy "oci:$img/oci" "dir:$img/dir" >/dev/null || { echo "skopeo cannot copy: its policy is missing" >&2; exit 1; }
buildah --storage-driver vfs pull "oci:$img/oci" >/dev/null || { echo "buildah cannot pull: its policy is missing" >&2; exit 1; }
rm -rf "$img"
# Rootless networking is what the old passt broke. Where an unprivileged user cannot create
# a user namespace (some nested containers) the check cannot run; say so instead of passing silently.
id smoke >/dev/null 2>&1 || useradd -m smoke
grep -q '^smoke:' /etc/subuid || echo 'smoke:100000:65536' >> /etc/subuid
grep -q '^smoke:' /etc/subgid || echo 'smoke:100000:65536' >> /etc/subgid
chmod -R a+rX "$root"
# pasta itself, with the option Podman passes, as an unprivileged user: needs no helper binaries.
if su smoke -c 'unshare -Un true' 2>/dev/null; then
	su smoke -c 'pasta --config-net --map-guest-addr 169.254.1.2 -- true' >/dev/null 2>&1 \
		|| { echo "pasta did not start with --map-guest-addr as an unprivileged user" >&2; exit 1; }
fi
rootless() { su smoke -c "mkdir -p /tmp/xdg-smoke && HOME=/home/smoke XDG_RUNTIME_DIR=/tmp/xdg-smoke $*" 2>&1; }
if rootless podman unshare true >/dev/null; then
	out="$(rootless podman --storage-driver vfs run --rm --network pasta --rootfs "$root" /usr/bin/echo rootless-ok || true)"
	case "$out" in *rootless-ok) ;; *) echo "a rootless container with pasta did not run: $out" >&2; exit 1 ;; esac
else
	echo "rootless check skipped: Podman cannot create its user namespace for an unprivileged user here"
fi
echo "smoke test passed: podman $version"
