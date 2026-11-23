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
check "the host-side listener is not started with httpd, which the image lacks" 0 "$(grep -v '^\s*#' "$HERE/scripts/package/verify/runtime-checks.sh" | grep -c 'httpd')"
check "and it is nc kept listening with -ll on port 18473, which it serves on :: as well" "1" "$(grep -c 'nc -ll -p 18473' "$HERE/scripts/package/verify/runtime-checks.sh")"
check "and it is waited for by reading the listening sockets of tcp and tcp6, with a bounded number of tries, and never by connecting to it" "1 1 0" "$(grep -c 'for _ in $(seq 1 30); do listener_up' "$HERE/scripts/package/verify/runtime-checks.sh") $(grep -c "listener_up() { awk '\$4 == \"0A\" && \$2 ~ /:4829\$/" "$HERE/scripts/package/verify/runtime-checks.sh") $(grep -c '/dev/tcp/127.0.0.1/18473' "$HERE/scripts/package/verify/runtime-checks.sh")"
check "and when it does not answer the check shows why, with the sockets of tcp and tcp6" "1 1 1" "$(grep -c 'the listener is not up' "$HERE/scripts/package/verify/runtime-checks.sh") $(grep -c 'sockets of tcp:' "$HERE/scripts/package/verify/runtime-checks.sh") $(grep -c 'cat /proc/net/tcp6' "$HERE/scripts/package/verify/runtime-checks.sh")"
# After the last stop the pasta of the network goes a moment later (the container killed after its second has to be
# reaped first, which took longer on x86_64 than on aarch64 in the CI): it is waited for, at most ten seconds, and a
# pasta that stays is shown with its parent, age, network and the containers of the user, never read as "sometimes".
check "the last pasta is waited for in steps of a fifth, ten seconds at most" "1 1" "$(grep -c '^	for _ in $(seq 0 50); do$' "$HERE/scripts/package/verify/runtime-checks.sh") $(grep -c '^		sleep 0.2$' "$HERE/scripts/package/verify/runtime-checks.sh")"
check "one that stays is shown with ps, its network and the containers of the user, and fails" "1 1 1" \
	"$(grep -c 'ps -o pid,ppid,etimes,user,args' "$HERE/scripts/package/verify/runtime-checks.sh") $(grep -c 'rl state' "$HERE/scripts/package/verify/runtime-checks.sh") $(grep -c 'is still running after waiting' "$HERE/scripts/package/verify/runtime-checks.sh")"
check "and the check no longer asks only for the first one at the instant" 0 "$(grep -c 'test -z "$(pasta_left)"' "$HERE/scripts/package/verify/runtime-checks.sh")"
check "the checks that need a machine of the distribution name themselves in the log" 1 "$(grep -c 'echo "== \$name"' "$SCRIPT")"

# --- the repository: its metadata is made before, in the build container, and read by every image ---
WORKM="$(mktemp -d)"
trap 'rm -rf "$WORKM"' EXIT
sed -n '/^pm_make_metadata() {/,/^}/p' "$SCRIPT" > "$WORKM/pm_make_metadata.sh"
check "the function that makes the metadata when there is none is found" 1 "$(grep -c '^pm_make_metadata() {' "$WORKM/pm_make_metadata.sh")"
mkdir -p "$WORKM/bin" "$WORKM/withmeta/repodata" "$WORKM/without"
: > "$WORKM/withmeta/repodata/repomd.xml"
for tool in dnf zypper createrepo_c; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$tool" "$WORKM" > "$WORKM/bin/$tool"
	chmod +x "$WORKM/bin/$tool"
done
meta() { # <family> <dir> -> exit status and the calls of the tools
	: > "$WORKM/calls"
	( PATH="$WORKM/bin:$PATH"; export family="$1"; . "$WORKM/pm_make_metadata.sh"; pm_make_metadata "$2" ) > /dev/null 2>&1
	echo "$? $(paste -sd'|' "$WORKM/calls")"
}
check "with the metadata made before, no tool is asked for anything, on every family" "0 |0 |0 " "$(meta el "$WORKM/withmeta")|$(meta suse "$WORKM/withmeta")|$(meta fedora "$WORKM/withmeta")"
check "without it on an EL image, dnf installs the tool and it makes the metadata" "0 dnf install -y createrepo_c|createrepo_c $WORKM/without" "$(meta el "$WORKM/without")"
check "and on openSUSE, zypper does" "0 zypper --non-interactive install --no-recommends createrepo_c|createrepo_c $WORKM/without" "$(meta suse "$WORKM/without")"
check "the repository of the proof is the packages and the metadata made before, copied together" 1 "$(grep -c 'cp -r "$rpms/repodata" "$repo/"' "$SCRIPT")"
check "and the repositories are no longer made by installing the tool in the two package managers' branches" 0 "$(sed -n '/^pm_add_repo() {/,/^}/p; /pm_add_repo() {/,/} ;;/p' "$SCRIPT" | grep -c 'createrepo_c')"

# --- the update step: it replaces the distribution's podman where there is one, and installs ours where there is none ---
# Amazon Linux 2023 has buildah and skopeo and no podman: an update there has nothing to replace and installs nothing, which
# let the proof go on with no podman at all ("Nothing to do", then every check on podman failing).
sed -n '/^pm_update_step() {/,/^}/p' "$SCRIPT" > "$WORKM/pm_update_step.sh"
check "the function of the update step is found" 1 "$(grep -c '^pm_update_step() {' "$WORKM/pm_update_step.sh")"
step() { # <before> -> what was run
	( pm_upgrade() { echo upgrade; }; pm_install() { echo "install $*"; }; . "$WORKM/pm_update_step.sh"; pm_update_step "$1" )
}
check "with the distribution's podman installed, the packages are upgraded" "upgrade" "$(step 'podman buildah skopeo')"
check "with podman in the middle of the list, too" "upgrade" "$(step 'buildah podman skopeo')"
check "with buildah and skopeo and no podman, podman is installed" "install podman" "$(step 'buildah skopeo')"
check "and a package whose name only contains podman (podman-docker) does not count as podman" "install podman" "$(step 'podman-docker buildah')"
check "the proof calls the step in both cases, and not pm_upgrade on its own" "0" "$(grep -c 'check "the update replaces the distribution.s packages" pm_upgrade' "$SCRIPT")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
