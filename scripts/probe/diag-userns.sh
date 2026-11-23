#!/usr/bin/env bash
#
# Why a user in a container cannot get a multi-id user namespace: prints what the process
# has (capabilities, no_new_privs, seccomp), what the setuid helper is, and tries the
# same mapping by hand. Run as root, on the runner itself or in a container.

set -u

echo "== $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"
grep -E '^(CapEff|CapBnd|NoNewPrivs|Seccomp)' /proc/self/status
for f in /proc/sys/kernel/apparmor_restrict_unprivileged_userns /proc/sys/kernel/apparmor_restrict_unprivileged_unconfined \
	/proc/sys/user/max_user_namespaces /proc/sys/kernel/unprivileged_userns_clone; do
	[ -e "$f" ] && echo "$f = $(cat "$f")"
done
ls -l "$(command -v newuidmap)" 2>&1
getcap "$(command -v newuidmap)" 2>&1 || true
cat /proc/self/uid_map
id t > /dev/null 2>&1 || useradd -m t
grep -q '^t:' /etc/subuid || echo 't:100000:65536' >> /etc/subuid
grep -q '^t:' /etc/subgid || echo 't:100000:65536' >> /etc/subgid
su t -s /bin/bash -c '
	grep -E "^(CapEff|CapBnd|NoNewPrivs)" /proc/self/status
	unshare -U sleep 20 &
	pid=$!
	sleep 1
	newuidmap "$pid" 0 "$(id -u)" 1 1 100000 65536
	echo "newuidmap rc=$?"
	cat "/proc/$pid/uid_map"
	kill "$pid"
'
