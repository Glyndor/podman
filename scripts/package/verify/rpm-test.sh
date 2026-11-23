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
image="${6:?image to run, by digest}"
case "$mode" in clean | upgrade) ;; *) echo "mode is clean or upgrade, not $mode" >&2; exit 2 ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+r([0-9]+)$ ]] || { echo "bad version, expected X.Y.Z+rR: $version" >&2; exit 2; }
revision="${BASH_REMATCH[1]}"
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
		pm_upgrade() { zypper --non-interactive update; }
		pm_add_repo() {
			zypper --non-interactive install --no-recommends createrepo_c \
				&& createrepo_c "$1" \
				&& zypper --non-interactive --no-gpg-checks addrepo --priority 90 "file://$1" glyndor-test \
				&& zypper --non-interactive --no-gpg-checks refresh glyndor-test
		} ;;
	*)
		pm_install() { dnf install -y "$@"; }
		pm_remove() { dnf remove -y "$@"; }
		pm_upgrade() { dnf upgrade -y; }
		pm_add_repo() {
			dnf install -y createrepo_c \
				&& createrepo_c "$1" \
				&& printf '[glyndor-test]\nname=Glyndor test repository\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\nrepo_gpgcheck=0\npriority=1\n' "$1" > /etc/yum.repos.d/glyndor-test.repo
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
check "podman is the Glyndor package at $nevr" test "$(rpm -q --qf '%{EPOCH}:%{VERSION}-%{RELEASE}\n' podman)" = "$nevr"
check "its vendor is Glyndor" test "$(vendor_of podman)" = Glyndor
check "the distribution's podman is not installed beside it" test "$(rpm -q podman | wc -l)" -eq 1
for pkg in netavark aardvark-dns containers-common; do
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

# --- containers as root --------------------------------------------------------------------------------
# vfs, because the storage of a container is itself an overlay filesystem, on which the overlay
# driver cannot be stacked.
p() { podman --storage-driver vfs "$@"; }
check "podman info answers" p info
check "the image is pulled by digest" p pull "docker://$image"
check "a container runs as root" bash -c "[ \"\$(podman --storage-driver vfs run --rm --network none '$image' echo root-ok)\" = root-ok ]"
dns_in() { # <podman prefix> <network>: a container finds another one by name on a bridge network
	local prefix="$1" net="$2" ip out
	$prefix network create "$net" > /dev/null || return 1
	$prefix run -d --name "$net-a" --network "$net" "$image" sleep 300 > /dev/null || return 1
	ip="$($prefix inspect "$net-a" --format "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}")"
	out="$($prefix run --rm --network "$net" "$image" nslookup "$net-a" 2>&1)" || { echo "$out"; return 1; }
	echo "$out"
	grep -q -F "$ip" <<< "$out" || { echo "the answer does not hold $ip"; return 1; }
}
check "a container resolves another by name on a bridge network (netavark and aardvark-dns), root" dns_in "podman --storage-driver vfs" rootnet
p rm -f rootnet-a > /dev/null 2>&1 || true

# --- containers without root ----------------------------------------------------------------------------
id probe > /dev/null 2>&1 || useradd -m probe
grep -q '^probe:' /etc/subuid || echo 'probe:100000:65536' >> /etc/subuid
grep -q '^probe:' /etc/subgid || echo 'probe:100000:65536' >> /etc/subgid
uid="$(id -u probe)"
install -d -m 0755 /run/user
install -d -m 0700 -o probe "/run/user/$uid"
cat > /tmp/rootless.sh <<ROOTLESS
set -u
export HOME=/home/probe XDG_RUNTIME_DIR=/run/user/$uid
P="podman --storage-driver vfs"
case "\$1" in
	userns) \$P unshare true ;;
	pull) \$P pull "docker://$image" ;;
	run) [ "\$(\$P run --rm --network pasta "$image" echo rootless-ok)" = rootless-ok ] ;;
	host) [ "\$(\$P run --rm --network pasta "$image" wget -q -T 20 -O - http://host.containers.internal:18473/probe)" = pasta-ok ] ;;
	dns)
		\$P network create rlnet > /dev/null || exit 1
		\$P run -d --name rl-a --network rlnet "$image" sleep 300 > /dev/null || exit 1
		ip="\$(\$P inspect rl-a --format '{{(index .NetworkSettings.Networks "rlnet").IPAddress}}')"
		out="\$(\$P run --rm --network rlnet "$image" nslookup rl-a 2>&1)" || { echo "\$out"; exit 1; }
		echo "\$out"
		case "\$out" in *"\$ip"*) ;; *) echo "the answer does not hold \$ip"; exit 1 ;; esac ;;
	stop-cli) \$P stop -t 1 rl-a ;;
	stop-api)
		\$P run -d --name rl-b --network rlnet "$image" sleep 300 > /dev/null || exit 1
		sock="/run/user/$uid/rl-api.sock"
		\$P system service --time 0 "unix://\$sock" > /tmp/rl-service.log 2>&1 &
		for _ in \$(seq 1 50); do [ -S "\$sock" ] && break; sleep 0.2; done
		code="\$(curl -sS -o /tmp/rl-stop.body -w '%{http_code}' --unix-socket "\$sock" -X POST "http://d/v5.0.0/libpod/containers/rl-b/stop?t=1")"
		kill %1 2> /dev/null
		echo "the API answered \$code: \$(cat /tmp/rl-stop.body)"
		[ "\$code" = 204 ] ;;
esac
ROOTLESS
rl() { runuser -u probe -- bash /tmp/rootless.sh "$1"; }
pasta_left() { grep -l '^pasta' /proc/[0-9]*/comm 2> /dev/null | head -n 1; }
# What decides whether an unprivileged user can get a namespace here, written down for the run that fails.
note "kernel.apparmor_restrict_unprivileged_userns=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>&1) user.max_user_namespaces=$(cat /proc/sys/user/max_user_namespaces 2>&1) newuidmap=$(command -v newuidmap)"
check "an unprivileged user can map ids and Podman can create its namespace" rl userns
if rl userns > /dev/null 2>&1; then
	check "the image is pulled, rootless" rl pull
	check "a container runs on pasta, rootless" rl run
	# A listener on this machine, fetched from inside a rootless container through the address
	# Podman maps to the host: the option an older pasta does not have.
	p run -d --name hostlisten --network host "$image" sh -c 'mkdir -p /www && echo pasta-ok > /www/probe && httpd -f -p 18473 -h /www' > /dev/null 2>&1 || true
	sleep 1
	check "a rootless container reaches the host through pasta" rl host
	p rm -f hostlisten > /dev/null 2>&1 || true
	check "a rootless container resolves another by name on a bridge network" rl dns
	check "the last containers of a rootless bridge network stop with the command" rl stop-cli
	check "the last container of a rootless bridge network stops through the API" rl stop-api
	check "no pasta is left running after the last container stopped" test -z "$(pasta_left)"
else
	note "an unprivileged user cannot map ids here: the rootless checks cannot run, and that is a failure"
	failed+=("rootless")
fi

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
