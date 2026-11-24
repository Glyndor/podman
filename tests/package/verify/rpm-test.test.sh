#!/usr/bin/env bash
#
# Tests for scripts/package/verify/rpm-test.sh as far as a stand-in reaches: its argument
# contract. It installs a package with the package manager of a distribution, as root, in a
# privileged container, and nothing here can be that; its real run is in
# .github/workflows/reusable-package.yml, which package-check.yml runs on a pull request that
# changes how the packages are built and release.yml runs before anything is signed.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/verify/rpm-test.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/rpms"
img=quay.io/libpod/alpine@sha256:fa93b01658e3a5a1686dc3ae55f170d8de487006fb53a28efcd12ab0710a2e5f
bash "$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"
bash "$SCRIPT" "$WORK/rpms" fc45 6.2.0+r12 6.2.0 sideways "$img" > /dev/null 2>&1; check "a mode that is neither clean nor upgrade is a usage error" 2 "$?"
bash "$SCRIPT" "$WORK/rpms" fc45 6.2.0 6.2.0 clean "$img" > /dev/null 2>&1; check "a version with no revision is a usage error" 2 "$?"
bash "$SCRIPT" "$WORK/absent" fc45 6.2.0+r12 6.2.0 clean "$img" > /dev/null 2>&1; check "a directory of packages that is not there is refused" 1 "$?"
bash "$SCRIPT" "$WORK/rpms" nope 6.2.0+r12 6.2.0 clean "$img" > /dev/null 2>&1; check "a distribution the table does not have is refused" 1 "$?"
# A machine with bash and nothing else lacks every program the proof runs: it is refused, every one named, and
# nothing was installed (no package manager was asked).
mkdir "$WORK/bare"
for tool in bash awk grep sed tr sort dirname cat head; do ln -s "$(type -P "$tool")" "$WORK/bare/$tool"; done
out="$(PATH="$WORK/bare" "$WORK/bare/bash" "$SCRIPT" "$WORK/rpms" fc45 6.2.0+r12 6.2.0 clean "$img" 2>&1)"; rc=$?
check "a machine without the programs of the proof is refused" "1" "$rc"
check "and every one of them is named, before anything is installed" "runuser useradd newuidmap newgidmap getcap curl rpm" \
	"$(printf '%s\n' "$out" | sed -n 's/^this container lacks://p' | tr ' ;' '\n\n' | grep -x -e runuser -e useradd -e newuidmap -e newgidmap -e getcap -e curl -e rpm | paste -sd' ')"
check "and nothing of the proof ran" 0 "$(printf '%s\n' "$out" | grep -c '^== ')"
for tool in runuser useradd newuidmap newgidmap getcap curl; do
	check "the list of the proof names $tool" 1 "$(grep -c -x "$tool" "$HERE/scripts/package/verify/test-tools.txt")"
done
check "the proof does not use su, which a minimal image lacks" 0 "$(grep -v '^\s*#' "$SCRIPT" | grep -c -E '(^|[^a-z_-])su (probe|-)')"
# The image the containers run (Podman's own alpine) has nc and wget and no httpd: a listener that used httpd
# never started, and pasta answered "connection refused" for it. The listener is waited for in /proc/net/tcp,
# since connecting to it would take its one request.
check "the host-side listener is not started with httpd, which the image lacks" 0 "$(grep -v '^\s*#' "$SCRIPT" | grep -c 'httpd')"
check "and it is nc kept listening with -ll on port 18473, which it serves on :: as well" "1" "$(grep -c 'nc -ll -p 18473' "$SCRIPT")"
check "and it is waited for by connecting to it, with a bounded number of tries, and not by reading /proc/net/tcp" "1 0" "$(grep -c 'for _ in $(seq 1 30); do listener_up' "$SCRIPT") $(grep -c '00000000:4829' "$SCRIPT")"
check "and when it does not answer the check shows why, with the sockets of tcp and tcp6" "1 1 1" "$(grep -c 'the listener is not up' "$SCRIPT") $(grep -c 'sockets of tcp:' "$SCRIPT") $(grep -c '/proc/net/tcp6' "$SCRIPT")"
# After the last stop the pasta of the network goes a moment later (the container killed after its second has to be
# reaped first, which took longer on x86_64 than on aarch64 in the CI): it is waited for, at most ten seconds, and a
# pasta that stays is shown with its parent, age, network and the containers of the user, never read as "sometimes".
check "the last pasta is waited for in steps of a fifth, ten seconds at most" "1 1" "$(grep -c '^	for _ in $(seq 1 50); do$' "$SCRIPT") $(grep -c '^		sleep 0.2$' "$SCRIPT")"
check "one that stays is shown with ps, its network and the containers of the user, and fails" "1 1 1" \
	"$(grep -c 'ps -o pid,ppid,etimes,user,args' "$SCRIPT") $(grep -c 'rl state' "$SCRIPT") $(grep -c 'is still running ten seconds after' "$SCRIPT")"
check "and the check no longer asks only for the first one at the instant" 0 "$(grep -c 'test -z "$(pasta_left)"' "$SCRIPT")"
check "the checks that need a machine of the distribution name themselves in the log" 1 "$(grep -c 'echo "== \$name"' "$SCRIPT")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
