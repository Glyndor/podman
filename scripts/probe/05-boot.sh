#!/usr/bin/env bash
#
# Step 5: start containers with what steps 3 and 4 installed. As root: the engine
# answers, an image is pulled and runs, a bridge network starts (netavark), and a
# container finds another one by name (aardvark-dns). As an unprivileged user with
# subuid and subgid ranges: a container runs on pasta, reaches the network, and finds
# another one by name on a bridge network of its own. Every check is recorded on its own
# and the script goes on after a failure, so one run measures all of them.
#
# Exit 3 when step 3 did not install anything.
#
# Usage: PODMAN_IMAGE=<image by digest> 05-boot.sh

# shellcheck disable=SC2317
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
image="${PODMAN_IMAGE:?image to run, by digest}"

[ "$(fact_get install)" = ok ] || { echo "nothing was installed"; exit 3; }

status=0
check() { # <fact> <description> <command...>
	local key="$1" what="$2" log
	shift 2
	log="$PROBE_OUT/logs/boot-$key.log"
	echo "== $what"
	if timeout 300 bash -c '"$@"' _ "$@" > "$log" 2>&1; then
		fact "boot.$key" ok
		tail -n 5 "$log"
	else
		fact "boot.$key" fail
		cat "$log"
		fail "$what"
		status=1
	fi
}

# netavark 2 has no iptables driver; a distribution that names it in its own
# containers.conf would stop every bridge network.
printf '[network]\nfirewall_driver = "nftables"\n' > "$PROBE_OUT/firewall.conf"
export CONTAINERS_CONF_OVERRIDE="$PROBE_OUT/firewall.conf"

# vfs because the storage of a container is itself an overlay filesystem, on which
# the overlay driver cannot be stacked.
p() { podman --storage-driver vfs "$@"; }
info() {
	p info --format 'runtime={{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Version}} conmon={{.Host.Conmon.Version}} network={{.Host.NetworkBackend}} cgroups={{.Host.CgroupManager}}' \
		&& p info > /dev/null
}
root_bridge() {
	p network create probe && p run --rm --network probe "$image" echo net-ok
}
export image PROBE_OUT CONTAINERS_CONF_OVERRIDE
export -f p info root_bridge
check info "podman info" info
fact boot.info-line "$(head -n 1 "$PROBE_OUT/logs/boot-info.log")"
check pasta-option "pasta offers --map-guest-addr" bash -c 'pasta --help 2>&1 | grep -q -- --map-guest-addr'
check pull "pull the test image by digest" p pull "docker://$image"
check root-run "a container runs as root" p run --rm --network none "$image" echo probe-ok
check root-bridge "a container starts on a bridge network" root_bridge

dns_root() {
	p run -d --name probe-a --network probe "$image" sleep 300 || return 1
	local ip out
	ip="$(p inspect probe-a --format '{{(index .NetworkSettings.Networks "probe").IPAddress}}')"
	out="$(p run --rm --network probe "$image" nslookup probe-a)" || { echo "$out"; return 1; }
	echo "$out"
	grep -q -F "$ip" <<< "$out" || { echo "the answer does not hold $ip"; return 1; }
}
export -f dns_root
check root-dns "a container resolves another by name (aardvark-dns), root" dns_root
p rm -f probe-a > /dev/null 2>&1 || true

# Rootless needs newuidmap and newgidmap to be setuid root or to carry file capabilities.
# A container image that lost either in its layers cannot map a range of ids, which is the
# image and not the distribution: the package is reinstalled in its place, and the result
# says it was.
pm_try libcap libcap-progs > /dev/null
helper_state() {
	local f
	f="$(command -v newuidmap)" || { echo missing; return; }
	if [ -u "$f" ]; then echo setuid
	elif getcap "$f" 2> /dev/null | grep -q cap_setuid; then echo filecaps
	else echo none; fi
}
state="$(helper_state)"
if [ "$state" = none ]; then
	case "$PM" in
		dnf) rpm --setperms shadow-utils; rpm --setcaps shadow-utils ;;
		zypper) rpm --setperms shadow; rpm --setcaps shadow ;;
		pacman) pacman -S --noconfirm shadow ;;
	esac
	state="none in the image, $(helper_state) after restoring them from the package"
fi
fact boot.newuidmap "$state"
{ ls -l "$(command -v newuidmap)" "$(command -v newgidmap)"; getcap "$(command -v newuidmap)" "$(command -v newgidmap)"
	grep -E '^(CapEff|CapBnd|NoNewPrivs|Seccomp)' /proc/self/status; } > "$PROBE_OUT/logs/boot-newuidmap.log" 2>&1

# Rootless. The user gets subuid and subgid ranges if the distribution's useradd gave none.
id probe > /dev/null 2>&1 || useradd -m probe
grep -q '^probe:' /etc/subuid || echo 'probe:100000:65536' >> /etc/subuid
grep -q '^probe:' /etc/subgid || echo 'probe:100000:65536' >> /etc/subgid
# The runtime directory a login session would give the user: the rootless storage
# configuration of the package puts its runroot under /run/user/<uid>.
uid="$(id -u probe)"
install -d -m 0755 /run/user
install -d -m 0700 -o probe "/run/user/$uid"
cat > "$PROBE_OUT/rootless.sh" <<ROOTLESS
set -u
export HOME=/home/probe XDG_RUNTIME_DIR=/run/user/$uid CONTAINERS_CONF_OVERRIDE="$PROBE_OUT/firewall.conf"
P="podman --storage-driver vfs"
case "\$1" in
	userns) unshare -Ur true && \$P unshare true ;;
	pull) \$P pull "docker://$image" ;;
	run) \$P run --rm --network pasta "$image" echo rootless-ok ;;
	runas) \$P run --rm --network pasta:--runas,0 "$image" echo rootless-ok ;;
	open)
		chmod 0755 "/run/user/\$(id -u)"
		\$P run --rm --network pasta "$image" echo rootless-ok ;;
	debug) \$P run --rm --network pasta:--debug "$image" echo rootless-ok ;;
	diag)
		pasta --version | head -n 1
		getent passwd nobody
		ls -ld /run /run/user "/run/user/\$(id -u)" "/run/user/\$(id -u)/netns" 2>&1
		\$P unshare cat /proc/self/uid_map
		\$P unshare id ;;
	net) \$P run --rm --network pasta "$image" wget -q -T 30 -O /dev/null http://example.com/ ;;
	dns)
		\$P network create probe-rl || exit 1
		\$P run -d --name rl-a --network probe-rl "$image" sleep 300 || exit 1
		ip="\$(\$P inspect rl-a --format '{{(index .NetworkSettings.Networks "probe-rl").IPAddress}}')"
		out="\$(\$P run --rm --network probe-rl "$image" nslookup rl-a)" || { echo "\$out"; exit 1; }
		echo "\$out"
		case "\$out" in *"\$ip"*) ;; *) echo "the answer does not hold \$ip"; exit 1 ;; esac ;;
esac
ROOTLESS
chmod 0644 "$PROBE_OUT/rootless.sh"
rl() { su probe -s /bin/bash -c "bash $PROBE_OUT/rootless.sh $1"; }
export -f rl
check rootless-userns "an unprivileged user can create a user namespace and Podman can too" rl userns
if [ "$(fact_get boot.rootless-userns)" = ok ]; then
	check rootless-pull "pull the test image, rootless" rl pull
	check rootless-run "a container runs on pasta, rootless" rl run
	if [ "$(fact_get boot.rootless-run)" != ok ]; then
		# What pasta runs as and where it looks, and whether keeping it as the user changes the answer.
		rl diag > "$PROBE_OUT/logs/boot-rootless-diag.log" 2>&1
		rl debug > "$PROBE_OUT/logs/boot-rootless-pasta-debug.log" 2>&1
		check rootless-run-open-rundir "the same with the runtime directory open to everyone" rl open
		check rootless-run-runas0 "the same with pasta kept as root of the namespace" rl runas
	fi
	check rootless-net "a rootless container on pasta reaches the network" rl net
	check rootless-dns "a rootless container resolves another by name (aardvark-dns)" rl dns
else
	for k in rootless-pull rootless-run rootless-net rootless-dns; do fact "boot.$k" skip; done
fi
exit "$status"
