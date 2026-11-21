#!/usr/bin/env bash
#
# Tests for scripts/verify/smoke-test.sh. Only the argument contract runs here:
# the install and the container run need root on Debian 13 and are exercised by
# the release workflow, not by this suite. What the script asks of the installed
# package (the seccomp profile, the distribution's copies gone, buildah and skopeo
# kept, the option pasta must have, two containers that find each other by name) is
# run by package-state.sh, whose own suite runs each check; this one reads
# smoke-test.sh and fails when a call to it is gone, since a call replaced by `:`
# leaves that suite green and the check unmade.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/smoke-test.sh"
pass=0; fail=0

check() { # <desc> <want-exit> <got-exit>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want exit $2, got $3)"; fi
}

rc=0; "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "no arguments fails" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
"$SCRIPT" /nonexistent.deb 6.2.0 >/dev/null 2>&1; check "missing deb fails with 2" 2 "$?"

# calls <file> <line>: how many times the file runs exactly this line, comments left out.
calls() { grep -v '^[[:space:]]*#' "$1" | grep -c -x -F -- "$2"; }
for line in 'bash "$here/package-state.sh" seccomp' \
	'bash "$here/package-state.sh" replaced golang-github-containers-common' \
	'bash "$here/package-state.sh" replaced passt' \
	'bash "$here/package-state.sh" kept buildah skopeo' \
	'bash "$here/package-state.sh" pasta-option' \
	'bash "$here/package-state.sh" dns smoke "$root"'; do
	check "the smoke test runs: ${line#bash \"\$here/package-state.sh\" }" 1 "$(calls "$SCRIPT" "$line")"
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sed 's/^bash "\$here\/package-state.sh" seccomp$/: package-state seccomp/' "$SCRIPT" > "$WORK/replaced.sh"
check "a call replaced by a no-op is not counted" 0 "$(calls "$WORK/replaced.sh" 'bash "$here/package-state.sh" seccomp')"
sed 's/^bash "\$here\/package-state.sh" seccomp$/# bash "$here\/package-state.sh" seccomp/' "$SCRIPT" > "$WORK/commented.sh"
check "nor is one that is only commented out" 0 "$(calls "$WORK/commented.sh" 'bash "$here/package-state.sh" seccomp')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
