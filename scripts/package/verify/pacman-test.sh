#!/usr/bin/env bash
#
# Prove the pacman packages of this repository on a clean Arch Linux, with pacman, before they are
# signed or published: the command the README gives replaces the Podman of Arch and what it
# carried, the packages are what they say, containers run with and without root, containers find
# each other by name, the last container of a rootless network stops, and the packages uninstall.
#
# Run as root inside a privileged Arch container, with the packages in <pkg-dir>. They are put in a
# repository of their own on disk, listed before [core] as the channel's configuration lists the
# Glyndor repository, and installed with `pacman -Syu --needed podman`, the command of the README
# (`replaces` only acts in a system upgrade; `-Sy podman` on a host with Arch's Podman stops on a
# conflict).
#
#   clean    install on the image as it is
#   upgrade  install Arch's podman, buildah and podman-docker first: the update must replace them,
#            and buildah, which depends on containers-common, must stay
#
# Every check runs even when an earlier one failed; the exit status is 1 when any failed.
#
# Usage: pacman-test.sh <pkg-dir> <version X.Y.Z+rR> <podman X.Y.Z> <clean|upgrade> <image>
#   <image> is the container image the started containers run, a reference by digest.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$(cd "$here/../.." && pwd)"
pkgs="$(cd "${1:?package dir}" && pwd)"
version="${2:?version X.Y.Z+rR}"
podman_version="${3:?podman version}"
mode="${4:?clean or upgrade}"
# shellcheck disable=SC2034 # read by runtime-checks.sh, which this script sources
image="${5:?image to run, by digest}"
case "$mode" in clean | upgrade) ;; *) echo "mode is clean or upgrade, not $mode" >&2; exit 2 ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+r[0-9]+$ ]] || { echo "bad version, expected X.Y.Z+rR: $version" >&2; exit 2; }

# What this script runs on the machine has to be there before anything is installed on it: a program that is
# missing otherwise shows up minutes in, as the failure of the one check that needed it.
bash "$scripts/package/require-tools.sh" pacman "$here/test-tools.txt" || exit 1

# shellcheck source=engine-files.sh
. "$here/engine-files.sh"
failed=()
check() { # <name> <command...>: run it, say how it went, and go on
	local name="$1"
	shift
	echo "== $name"
	if "$@"; then echo "ok    $name"; else echo "FAIL  $name"; failed+=("$name"); fi
}
note() { echo "-- $*"; }

# A CI container owns its cgroup but passes no controllers down to children.
if [ -w /sys/fs/cgroup/cgroup.subtree_control ]; then
	mkdir -p /sys/fs/cgroup/pacman-test-init
	echo $$ > /sys/fs/cgroup/pacman-test-init/cgroup.procs 2> /dev/null || true
	for c in $(cat /sys/fs/cgroup/cgroup.controllers); do
		echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2> /dev/null || true
	done
fi
# The image of Arch can lose the setuid bit of newuidmap in its layers; a normal installation has it.
path="$(command -v newuidmap 2> /dev/null || true)"
if [ -n "$path" ] && [ ! -u "$path" ]; then
	note "newuidmap is not setuid in this image; reinstalling shadow"
	pacman -S --noconfirm shadow > /dev/null 2>&1 || true
fi

before=""
if [ "$mode" = upgrade ]; then
	if pacman -Syu --noconfirm --needed podman buildah podman-docker > /tmp/before.log 2>&1; then
		before="podman buildah podman-docker"
		note "installed before the update: $(pacman -Q podman buildah podman-docker | paste -sd' ')"
	else
		cat /tmp/before.log
		note "Arch's podman could not be installed to start from"
		failed+=("the distribution's podman installs")
	fi
fi

# What the administrator changed in Arch's containers-common: policy.json says which images may be pulled. The
# package does not replace containers-common, so the file stays where it is, active and as written.
changed=0
if [ "$mode" = upgrade ] && [ -f /etc/containers/policy.json ]; then
	printf '%s\n' '{"default":[{"type":"insecureAcceptAnything"}],"transports":{}}' > /etc/containers/policy.json
	changed=1
fi

repo="$(mktemp -d)"
# pacman downloads as an unprivileged user, which has to be able to enter the directory.
chmod 0755 "$repo"
cp "$pkgs"/*.pkg.tar.zst "$repo/"
add_repo() {
	repo-add "$repo/glyndor.db.tar.zst" "$repo"/*.pkg.tar.zst > /dev/null \
		&& sed -i "/^\[core\]/i [glyndor]\nSigLevel = Never\nServer = file://$repo\n" /etc/pacman.conf
}
check "the packages are put in a repository listed before core" add_repo
# The command of the README, as it is written there.
check "the system is upgraded with the command of the README" pacman -Syu --needed --noconfirm podman

installed() { pacman -Q "$1" > /dev/null 2>&1; }
if [ "$changed" = 1 ]; then
	check "the policy.json the administrator wrote is the active one after the update" grep -q '"transports":{}' /etc/containers/policy.json
	check "containers-common of Arch is still installed, and podman does not own its files" bash -c "pacman -Q containers-common > /dev/null && ! pacman -Ql podman | grep -q 'usr/share/containers'"
fi
check "podman is the Glyndor package at $version-1" test "$(pacman -Q podman 2> /dev/null)" = "podman $version-1"
check "its packager is Glyndor" test "$(pacman -Qi podman | sed -n 's/^Packager *: //p')" = "Glyndor <noreply@glyndor.net>"
for pkg in netavark aardvark-dns; do
	# pacman -Q answers a name that a package only provides with the package that provides it.
	check "$pkg is provided by podman and is not a package of its own" test "$(pacman -Q "$pkg" 2> /dev/null | cut -d' ' -f1)" = podman
done
check "the files of netavark are podman's" test "$(pacman -Qqo /usr/libexec/podman/netavark 2> /dev/null)" = podman
check "container-network-stack is provided" bash -c "pacman -Qi podman | grep -q '^Provides.*container-network-stack=2'"
check "the libraries podman links are declared as dependencies, derived from the binaries" bash -c "pacman -Qi podman | grep -q '^Depends On.*libseccomp.so=2-64'"
check "netavark and aardvark-dns of the package are the ones that run" bash -c '/usr/libexec/podman/netavark --version && /usr/libexec/podman/aardvark-dns --version'
check "no file of the package is missing" bash -c "! pacman -Qk podman podman-docker 2>&1 | grep -E '[1-9][0-9]* missing files'"
check "the files a customer expects are on disk" ships_engine
check "the seccomp profile is the one of this release" bash "$scripts/verify/package-state.sh" seccomp
check "podman says the version that was built" bash "$scripts/verify/package-state.sh" version "$podman_version"
if [ "$mode" = upgrade ] && [ -n "$before" ]; then
	check "podman-docker was updated with podman" test "$(pacman -Q podman-docker 2> /dev/null)" = "podman-docker $version-1"
	check "buildah survived the replacement of containers-common" installed buildah
	check "buildah finds its policy and registries" bash -c 'buildah --version > /dev/null'
fi

# --- containers as root and without root ------------------------------------------------------
# shellcheck source=runtime-checks.sh
. "$here/runtime-checks.sh"

# --- uninstall ---------------------------------------------------------------------------------------------
p rm -af > /dev/null 2>&1 || true
check "podman and what depends on it uninstall" pacman -Rcns --noconfirm podman
check "nothing of the package is left in /usr/bin" test -z "$(ls /usr/bin/podman /usr/bin/podmansh /usr/bin/docker 2> /dev/null)"
check "nothing of the package is left in /usr/libexec/podman" test ! -e /usr/libexec/podman/netavark
check "no package of Podman is left installed" test -z "$(pacman -Qq 2> /dev/null | grep -x -e podman -e podman-docker -e netavark -e aardvark-dns)"

echo
if [ "${#failed[@]}" -gt 0 ]; then
	echo "pacman test failed ($mode): ${failed[*]}"
	exit 1
fi
echo "pacman test passed ($mode): podman $podman_version, $version-1"
