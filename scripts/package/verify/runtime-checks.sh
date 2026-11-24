# shellcheck shell=bash
# shellcheck disable=SC2154 # image, scripts and failed are the sourcing script's
#
# The part of the proof of a native package that does not depend on the package format: with
# the package installed, containers run as root and without it, containers on a bridge network
# find each other by name, a container reaches the host through pasta, and the last container
# of a rootless network stops, by the command and through the API. Sourced by rpm-test.sh and
# pacman-test.sh at the point where the package is installed, never run; the script that
# sources it has already defined `check`, `note`, the array `failed` and the variable `image`
# (the container image the containers run, by digest).

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
	host)
		got="\$(\$P run --rm --network pasta "$image" wget -q -T 20 -O - http://host.containers.internal:18473/probe 2>&1)"
		[ "\$got" = pasta-ok ] && exit 0
		echo "the answer was: \$got"
		# Where the container thought the host was, and what this machine listens on, for the log.
		\$P run --rm --network pasta "$image" sh -c 'grep internal /etc/hosts; ip -4 route 2> /dev/null || true' 2>&1
		grep -c ' 0A ' /proc/net/tcp | sed 's/^/listening sockets of this machine: /'
		exit 1 ;;
	dns)
		\$P network create rlnet > /dev/null || exit 1
		\$P run -d --name rl-a --network rlnet "$image" sleep 300 > /dev/null || exit 1
		ip="\$(\$P inspect rl-a --format '{{(index .NetworkSettings.Networks "rlnet").IPAddress}}')"
		out="\$(\$P run --rm --network rlnet "$image" nslookup rl-a 2>&1)" || { echo "\$out"; exit 1; }
		echo "\$out"
		case "\$out" in *"\$ip"*) ;; *) echo "the answer does not hold \$ip"; exit 1 ;; esac ;;
	stop-cli) \$P stop -t 1 rl-a ;;
	state) \$P ps -a --format '{{.Names}} {{.Status}}'; \$P network ls ;;
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
pasta_pids() { grep -l '^pasta' /proc/[0-9]*/comm 2> /dev/null | sed 's#/proc/\([0-9]*\)/comm#\1#'; }
# The pasta of a rootless bridge network goes when the last container of it does, but not in the same instant: the
# container that was killed after its second has to be reaped first. So it is waited for, up to ten seconds in steps
# of a fifth, and the log says how long it really took (0.000 s when none was left), so that a race, which gives a
# short wait, can be told from a leak, which gives the whole ten seconds. A pasta that is still there after that is
# shown with its command line, its parent, the namespace it lives in and the containers of the user.
pasta_gone() {
	local _ p left start elapsed
	start="$(date +%s%N)"
	for _ in $(seq 0 50); do
		left="$(pasta_pids)"
		elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
		if [ -z "$left" ]; then
			printf 'no pasta was left after waiting %d.%03d s\n' $((elapsed / 1000)) $((elapsed % 1000))
			return 0
		fi
		sleep 0.2
	done
	printf 'pasta is still running after waiting %d.%03d s, the whole ten seconds, after the last container stopped:\n' $((elapsed / 1000)) $((elapsed % 1000))
	for p in $left; do
		ps -o pid,ppid,etimes,user,args -p "$p" | tail -n +2
		echo "  parent: $(ps -o pid=,args= -p "$(ps -o ppid= -p "$p" | tr -d ' ')" 2>&1)"
		echo "  network namespace $(readlink "/proc/$p/ns/net") (this shell's is $(readlink /proc/self/ns/net))"
	done
	echo "containers and networks of the user:"
	rl state
	return 1
}
# What decides whether an unprivileged user can get a namespace here, written down for the run that fails.
note "kernel.apparmor_restrict_unprivileged_userns=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>&1) user.max_user_namespaces=$(cat /proc/sys/user/max_user_namespaces 2>&1) newuidmap=$(command -v newuidmap)"
check "an unprivileged user can map ids and Podman can create its namespace" rl userns
if rl userns > /dev/null 2>&1; then
	check "the image is pulled, rootless" rl pull
	check "a container runs on pasta, rootless" rl run
	# A listener on this machine, fetched from inside a rootless container through the address
	# Podman maps to the host: the option an older pasta does not have.
	# The listener of the host side: a server in a container on the network of this machine. The image has no
	# httpd, only nc, which is why it is nc; `-ll` keeps it listening for any number of connections, so asking
	# whether it is up does not use it up, and it listens on :: for both address families, which is why it is not
	# looked for in /proc/net/tcp alone. It is waited for by connecting to it, from this network, and when it does
	# not answer the check shows why: a server that never started once read as "connection refused" from pasta.
	listener_up() { (exec 3<> /dev/tcp/127.0.0.1/18473) 2> /dev/null; }
	p run -d --name hostlisten --network host "$image" sh -c 'nc -ll -p 18473 -e sh -c "printf \"HTTP/1.0 200 OK\r\nContent-Length: 9\r\n\r\npasta-ok\n\""' > /tmp/hostlisten.log 2>&1
	for _ in $(seq 1 30); do listener_up && break; sleep 0.5; done
	if ! listener_up; then
		note "the listener is not up: $(cat /tmp/hostlisten.log); $(p ps -a --format '{{.Names}} {{.Status}}' 2>&1 | paste -sd';'); $(p logs hostlisten 2>&1 | tail -n 5 | paste -sd';')"
		note "sockets of tcp: $(cat /proc/net/tcp | paste -sd'|'); sockets of tcp6: $(cat /proc/net/tcp6 2> /dev/null | paste -sd'|')"
	fi
	check "the listener of the host-side check answers on port 18473 of this machine" listener_up
	check "a rootless container reaches the host through pasta" rl host
	p rm -f hostlisten > /dev/null 2>&1 || true
	check "a rootless container resolves another by name on a bridge network" rl dns
	check "the last containers of a rootless bridge network stop with the command" rl stop-cli
	check "the last container of a rootless bridge network stops through the API" rl stop-api
	check "no pasta is left running after the last container stopped, waited for ten seconds at most" pasta_gone
else
	note "an unprivileged user cannot map ids here: the rootless checks cannot run, and that is a failure"
	failed+=("rootless")
fi
