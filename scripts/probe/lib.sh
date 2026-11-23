#!/usr/bin/env bash
#
# Shared by the steps of the distribution probe, which run as root inside the
# container of the distribution under test. Sourced, never run.
#
# Paths come from the environment so a test can point them elsewhere:
#   PROBE_OUT    results: facts.tsv, logs/, first-error.txt
#   PROBE_SRC    the three upstream trees: podman, netavark, aardvark-dns
#   PROBE_TOOLS  the toolchains the runner downloaded and verified
#   PROBE_ENV    file the steps write their PATH changes to, so the next step has them

PROBE_OUT="${PROBE_OUT:-/out}"
PROBE_SRC="${PROBE_SRC:-/src}"
PROBE_TOOLS="${PROBE_TOOLS:-/toolchains}"
PROBE_ENV="${PROBE_ENV:-/opt/probe-env.sh}"
mkdir -p "$PROBE_OUT/logs" "$(dirname "$PROBE_ENV")"
# shellcheck disable=SC1090
[ ! -f "$PROBE_ENV" ] || . "$PROBE_ENV"

# shellcheck disable=SC1091
. /etc/os-release
case "$ID" in
	fedora | rhel | almalinux | rocky | centos | amzn) PM=dnf ;;
	opensuse-tumbleweed | opensuse-leap | sles) PM=zypper ;;
	arch) PM=pacman ;;
	*) echo "PROBE-FAIL: no package manager known for $ID" >&2; exit 1 ;;
esac

# fact <key> <value>: one line of the result. The last value of a key wins.
fact() { printf '%s\t%s\n' "$1" "$2" >> "$PROBE_OUT/facts.tsv"; }

# fail <message>: the line the result reader looks for as the first error.
fail() { echo "PROBE-FAIL: $*" >&2; }

# use_path <dir>: put a directory first on PATH now and in the steps after this one.
use_path() {
	# The next step has to expand $PATH itself, so it goes in as text.
	# shellcheck disable=SC2016
	printf 'export PATH="%s:%s"\n' "$1" '$PATH' >> "$PROBE_ENV"
	export PATH="$1:$PATH"
}

# ver_ge <have> <need>: true when <have> is the same version as <need> or newer.
ver_ge() {
	[ -n "$1" ] || return 1
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

# The headers of the RHEL family live in a repository that is off by default, called crb
# or codeready-builder depending on the clone. It is a build-time repository: nothing
# installed from it is a run-time dependency. The subscription plugin of UBI prints a
# banner on every call and is switched off for it.
enable_build_repos() {
	case "$ID" in
		almalinux | rocky | rhel)
			if [ -f /etc/dnf/plugins/subscription-manager.conf ]; then
				sed -i 's/^enabled *=.*/enabled=0/' /etc/dnf/plugins/subscription-manager.conf
			fi
			dnf install -y dnf-plugins-core > /dev/null 2>&1 || true
			dnf repolist --all > "$PROBE_OUT/logs/repolist-before.log" 2>&1 || true
			for r in $(dnf repolist --all 2> /dev/null | awk '$1 ~ /(^crb$|codeready)/ {print $1}'); do
				dnf config-manager --set-enabled "$r" || true
			done
			dnf repolist > "$PROBE_OUT/logs/repolist.log" 2>&1 || true ;;
	esac
}

pm_refresh() {
	case "$PM" in
		dnf) enable_build_repos; dnf makecache -q || true ;;
		zypper) zypper --non-interactive --gpg-auto-import-keys refresh ;;
		pacman) pacman -Syu --noconfirm ;;
	esac
}

pm_install() {
	case "$PM" in
		dnf) dnf install -y --setopt=install_weak_deps=False "$@" ;;
		zypper) zypper --non-interactive install --no-recommends "$@" ;;
		pacman) pacman -S --noconfirm --needed "$@" ;;
	esac
}

# pm_try <package>...: install each one on its own and print the ones the repositories
# do not have, so an absent optional package is a line in the result, not a stop.
pm_try() {
	local p
	for p in "$@"; do
		pm_install "$p" > "$PROBE_OUT/logs/pm-try-$p.log" 2>&1 || echo "$p"
	done
}

# pm_version <package>: the version the repositories offer, empty when they have none.
pm_version() {
	case "$PM" in
		dnf)
			dnf repoquery --latest-limit=1 --queryformat '%{version}-%{release}\n' "$1" 2>/dev/null | grep -E '^[0-9]' | sort -V | tail -n 1 ;;
		zypper)
			zypper --non-interactive info "$1" 2>/dev/null | sed -n 's/^Version *: *//p' | head -n 1 ;;
		pacman)
			pacman -Si "$1" 2>/dev/null | sed -n 's/^Version *: *//p' | head -n 1 ;;
	esac
}

# upstream_version <package version> [date]: the part of a distribution version that is
# upstream's. With "date" the version is a passt snapshot and the 8-digit date comes out.
upstream_version() {
	if [ "${2:-}" = date ]; then
		printf '%s' "$1" | grep -oE '20[0-9]{2}_?[0-9]{2}_?[0-9]{2}' | tr -d _ | head -n 1
	else
		printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
	fi
}

# fact_get <key>: the last value written for a key, empty when there is none.
fact_get() {
	awk -F'\t' -v k="$1" '$1 == k {v = $2} END {print v}' "$PROBE_OUT/facts.tsv" 2> /dev/null
}

# dep_verdict <name>: ok, short or missing, as step 4 wrote it.
dep_verdict() { fact_get "dep.$1" | awk -F'|' '{print $3}'; }

# prepare_cgroups: a container owns its cgroup but passes no controllers to its children,
# so crun fails with "controller pids is not available". Every process of the container
# moves into a child cgroup and the controllers are enabled for the siblings, as
# smoke-test.sh does. It has to run in the first process of the container, before that
# one starts any other: a process left in the cgroup of the container keeps the
# controllers from being delegated.
prepare_cgroups() {
	[ -w /sys/fs/cgroup/cgroup.subtree_control ] || return 0
	mkdir -p /sys/fs/cgroup/probe-init
	echo $$ > /sys/fs/cgroup/probe-init/cgroup.procs 2> /dev/null || return 0
	local c
	for c in $(< /sys/fs/cgroup/cgroup.controllers); do
		echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2> /dev/null || true
	done
}
