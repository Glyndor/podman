#!/usr/bin/env bash
#
# Tests for scripts/verify/rootless-test.sh. Only the argument contract runs here:
# the script installs the package on the machine it runs on, so the rest is
# exercised on a hosted runner by the build workflow, not by this suite.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/rootless-test.sh"
pass=0; fail=0

check() { # <desc> <want-exit> <got-exit>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want exit $2, got $3)"; fi
}

if "$SCRIPT" >/dev/null 2>&1; then rc=0; else rc=1; fi; check "no arguments fails" 1 "$rc"
"$SCRIPT" /nonexistent.deb 6.2.0 >/dev/null 2>&1; check "missing deb fails with 2" 2 "$?"

# As root it must stop before it touches the machine: the point of the script is an
# unprivileged user. A stand-in `id` says 0; the deb exists so that is not what stops it.
shim="$(mktemp -d)"; trap 'rm -rf "$shim"' EXIT
printf '#!/bin/sh\necho 0\n' > "$shim/id"; chmod +x "$shim/id"
: > "$shim/x.deb"
out="$(PATH="$shim:$PATH" "$SCRIPT" "$shim/x.deb" 6.2.0 2>&1)"; rc=$?
check "root is refused with 2" 2 "$rc"
case "$out" in *"not as root"*) pass=$((pass + 1)); echo "ok    root is refused for being root" ;;
	*) fail=$((fail + 1)); echo "FAIL  root is refused for being root (got: $out)" ;; esac

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
