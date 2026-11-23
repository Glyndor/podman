#!/usr/bin/env bash
#
# Prove an rpm of this repository on a clean image of the distribution it is for, with the
# package manager of that distribution, before it is signed or published: it installs, it
# replaces the Podman the distribution ships, it starts containers with and without root,
# containers find each other by name, the last container of a rootless network stops, and it
# uninstalls. A package that installs and does not start is not published.
#
# Run as root inside a privileged container of the distribution, with the packages of one
# architecture in <rpm-dir>. The packages are put in a repository of their own on disk and
# installed from it by name, the way a channel's repository serves them.
#
#   clean    install on the image as it is
#   upgrade  install the distribution's podman, buildah, skopeo and podman-docker first, then
#            take the update from the repository: the Podman of the distribution must be
#            replaced, and what depends on its containers-common must stay
#
# Every check runs even when an earlier one failed, so one run says everything that is wrong;
# the exit status is 1 when any failed. The checks are named in the log.
#
# Usage: rpm-test.sh <rpm-dir> <id> <version X.Y.Z+rR> <podman X.Y.Z> <clean|upgrade> <image>
#   <image> is the container image the started containers run, a reference by digest.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$(cd "$here/../.." && pwd)"
rpms="$(cd "${1:?rpm dir}" && pwd)"
id="${2:?distribution id}"
version="${3:?version X.Y.Z+rR}"
podman_version="${4:?podman version}"
mode="${5:?clean or upgrade}"
# shellcheck disable=SC2034 # read by runtime-checks.sh, which this script sources
image="${6:?image to run, by digest}"
case "$mode" in clean | upgrade) ;; *) echo "mode is clean or upgrade, not $mode" >&2; exit 2 ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+r([0-9]+)$ ]] || { echo "bad version, expected X.Y.Z+rR: $version" >&2; exit 2; }
revision="${BASH_REMATCH[1]}"
# distros.sh reads the table with awk, which the minimal image of openSUSE does not have.
command -v awk > /dev/null || { zypper --non-interactive install gawk || dnf install -y gawk; } > /dev/null 2>&1 || true
epoch="$(bash "$scripts/package/distros.sh" field "$id" epoch)"
family="$(bash "$scripts/package/distros.sh" field "$id" family)"
nevr="$epoch:$version-$revision.glyndor.$id"

# What this script runs on the machine has to be there before anything is installed on it: a program that is
# missing otherwise shows up minutes in, as the failure of the one check that needed it.
bash "$scripts/package/require-tools.sh" rpm "$here/test-tools.txt" || exit 1

# --- what the distribution's package manager is called here ------------------------------------
case "$family" in
	suse)
		pm_install() { zypper --non-interactive install --no-recommends "$@"; }
		pm_remove() { zypper --non-interactive remove "$@"; }
		pm_upgrade() { zypper --non-interactive update --allow-vendor-change; }
		pm_reinstall() { zypper --non-interactive install --force "$@"; }
		pm_add_repo() {
			zypper --non-interactive install --no-recommends createrepo_c \
				&& createrepo_c "$1" \
				&& zypper --non-interactive addrepo --no-gpgcheck "file://$1" glyndor-test \
				&& zypper --non-interactive refresh glyndor-test
		} ;;
	*)
		pm_install() { dnf install -y "$@"; }
		pm_remove() { dnf remove -y "$@"; }
		pm_upgrade() { dnf upgrade -y; }
		pm_reinstall() { dnf reinstall -y "$@"; }
		pm_add_repo() {
			dnf install -y createrepo_c \
				&& createrepo_c "$1" \
				&& printf '[glyndor-test]\nname=Glyndor test repository\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\nrepo_gpgcheck=0\n' "$1" > /etc/yum.repos.d/glyndor-test.repo
		} ;;
esac

failed=()
check() { # <name> <command...>: run it, say how it went, and go on
	local name="$1"
	shift
	echo "== $name"
	if "$@"; then echo "ok    $name"; else echo "FAIL  $name"; failed+=("$name"); fi
}
note() { echo "-- $*"; }

# --- the machine ---------------------------------------------------------------------------------
# A CI container owns its cgroup but passes no controllers down to children, so the runtime
# fails with "controller pids is not available". Move this shell into a child cgroup and enable
# the controllers for the siblings, as the Docker-in-Docker entrypoint does.
if [ -w /sys/fs/cgroup/cgroup.subtree_control ]; then
	mkdir -p /sys/fs/cgroup/rpm-test-init
	echo $$ > /sys/fs/cgroup/rpm-test-init/cgroup.procs 2> /dev/null || true
	for c in $(cat /sys/fs/cgroup/cgroup.controllers); do
		echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2> /dev/null || true
	done
fi

# The image of a distribution can lose the setuid bit or the file capabilities of newuidmap in
# its layers, and without them no id range can be mapped. A normal installation has them.
for tool in newuidmap newgidmap; do
	path="$(command -v "$tool" 2> /dev/null || true)"
	if [ -n "$path" ] && [ ! -u "$path" ] && ! getcap "$path" 2> /dev/null | grep -q cap_set; then
		note "$tool has neither setuid nor capabilities in this image; restoring them from the package"
		case "$family" in suse) rpm --setperms shadow; rpm --setcaps shadow ;; *) rpm --setperms shadow-utils; rpm --setcaps shadow-utils ;; esac
	fi
done

owner() { rpm -qf --qf '%{NAME}\n' "$1" 2> /dev/null; }
vendor_of() { rpm -q --qf '%{VENDOR}\n' "$1" 2> /dev/null; }

# --- before: the distribution's own Podman, and what depends on its containers-common --------------
before=""
if [ "$mode" = upgrade ]; then
	for pkg in podman podman-docker buildah skopeo; do
		if pm_install "$pkg" > "/tmp/before-$pkg.log" 2>&1; then before="$before $pkg"; else note "the distribution has no $pkg to start from"; fi
	done
	note "installed before the update:$before"
	for pkg in $before; do rpm -q "$pkg"; done
fi

# --- the update, or the install ---------------------------------------------------------------------
repo="$(mktemp -d)"
cp "$rpms"/*.rpm "$repo/"
check "the packages are put in a repository the package manager reads" pm_add_repo "$repo"
if [ "$mode" = upgrade ] && [ -n "$before" ]; then
	check "the update replaces the distribution's packages" pm_upgrade
else
	check "podman installs from the repository" pm_install podman
fi

# --- what the package says ----------------------------------------------------------------------------
check "podman is the Glyndor package at $nevr" test "$(rpm -q --qf '%|EPOCH?{%{EPOCH}}:{0}|:%{VERSION}-%{RELEASE}\n' podman)" = "$nevr"
check "its vendor is Glyndor" test "$(vendor_of podman)" = Glyndor
check "the distribution's podman is not installed beside it" test "$(rpm -q podman | wc -l)" -eq 1
cc=containers-common
[ "$family" != suse ] || cc=libcontainers-common
for pkg in netavark aardvark-dns "$cc"; do
	check "$pkg is provided by podman and is not a package of its own" test "$(rpm -q --whatprovides "$pkg" 2> /dev/null | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')" = "podman "
done
check "netavark and aardvark-dns of the package are the ones that run" bash -c '/usr/libexec/podman/netavark --version && /usr/libexec/podman/aardvark-dns --version'
check "every file of the package is as the package says, configuration aside" test -z "$(rpm -V podman podman-docker podmansh 2>&1 | grep -v -e ' c /' -e 'is not installed' || true)"
check "the files a customer expects are on disk" bash "$scripts/verify/package-state.sh" ships
check "the seccomp profile is the one of this release" bash "$scripts/verify/package-state.sh" seccomp
check "podman says the version that was built" bash "$scripts/verify/package-state.sh" version "$podman_version"
if [ "$mode" = upgrade ]; then
	for pkg in $before; do
		case "$pkg" in
			podman-docker) check "podman-docker was updated with podman" test "$(vendor_of podman-docker)" = Glyndor ;;
			buildah | skopeo) check "$pkg survived the replacement of containers-common" rpm -q "$pkg" ;;
		esac
	done
fi
if [ "$mode" = upgrade ]; then
	check "buildah and skopeo find their policy and registries" bash -c 'command -v skopeo > /dev/null && skopeo --version > /dev/null && command -v buildah > /dev/null && buildah --version > /dev/null'
fi

# What the administrator changed under /etc survives. policy.json says which images may be pulled: it is
# a configuration file of the package that an update does not replace, whatever it holds.
check "policy.json is a configuration file of podman" bash -c "rpm -qc podman | grep -qx /etc/containers/policy.json"
cp /etc/containers/policy.json /tmp/policy.json.saved
echo '{"default":[{"type":"reject"}]}' > /etc/containers/policy.json
check "the package installed again leaves a policy.json the administrator changed" bash -c "$(declare -f pm_reinstall); pm_reinstall podman > /dev/null 2>&1 && grep -q reject /etc/containers/policy.json"
cp /tmp/policy.json.saved /etc/containers/policy.json

# --- containers as root and without root ------------------------------------------------------
# shellcheck source=runtime-checks.sh
. "$here/runtime-checks.sh"

# --- uninstall ---------------------------------------------------------------------------------------------
p rm -af > /dev/null 2>&1 || true
removed="podman"
for pkg in podman-docker podmansh; do rpm -q "$pkg" > /dev/null 2>&1 && removed="$removed $pkg"; done
# shellcheck disable=SC2086
check "podman and what depends on it uninstall" pm_remove $removed
check "nothing of the package is left in /usr/bin" test -z "$(ls /usr/bin/podman /usr/bin/podmansh /usr/bin/docker 2> /dev/null)"
check "nothing of the package is left in /usr/libexec/podman" test ! -e /usr/libexec/podman/netavark
check "no package of Podman is left installed" test -z "$(rpm -qa 'podman*' 'netavark*' 'aardvark-dns*')"

echo
if [ "${#failed[@]}" -gt 0 ]; then
	echo "rpm test failed on $id ($mode): ${failed[*]}"
	exit 1
fi
echo "rpm test passed on $id ($mode): podman $podman_version, $nevr"
