#!/usr/bin/env bash
#
# Tests for scripts/package/verify/prepare-runner.sh with a sudo that writes down what it was
# asked to do: the restriction on user namespaces is lifted, and the AppArmor profiles of passt
# and pasta are unloaded only when the runner has them.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/verify/prepare-runner.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin"
printf '#!/bin/sh\necho "sudo $*" >> "$CALLS"\ncase "$1" in aa-status) exit 1 ;; esac\n[ -z "$FAKE_SYSCTL_FAILS" ] || [ "$1" != sysctl ] || exit 1\nexit 0\n' > "$WORK/bin/sudo"
chmod +x "$WORK/bin/sudo"
export CALLS="$WORK/calls"
PATH="$WORK/bin:$PATH"
: > "$CALLS"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
check "the preparation succeeds" 0 "$rc"
check "user namespaces of an unprivileged user are allowed" 1 "$(grep -c -x 'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0' "$CALLS")"
check "and the runner says what it had loaded before and after" 2 "$(printf '%s\n' "$out" | grep -c -e 'before:' -e 'after:')"
check "no profile of this machine, none unloaded" "$(grep -c -e apparmor_parser "$CALLS")" "$(( $(ls /etc/apparmor.d/usr.bin.passt /etc/apparmor.d/usr.bin.pasta 2> /dev/null | wc -l) ))"
: > "$CALLS"
FAKE_SYSCTL_FAILS=1 bash "$SCRIPT" > /dev/null 2>&1; rc=$?
check "a sysctl that cannot be set stops the preparation, and the profiles are not touched" "1 0" "$rc $(grep -c apparmor_parser "$CALLS")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
