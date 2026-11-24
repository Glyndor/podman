#!/usr/bin/env bash
#
# Tests for scripts/package/verify/engine-files.sh: the two lists of what a customer expects on disk after a native
# package of Podman is installed, looked for under a root of the test's own.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$HERE/scripts/package/verify/engine-files.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=scripts/package/verify/engine-files.sh
. "$LIB"
export GLYNDOR_ROOT="$WORK/root"
mkdir -p "$GLYNDOR_ROOT"

out="$(ships_engine 2>&1)"; rc=$?
check "a machine without the engine is refused, naming the first file it lacks" "1 the package does not ship /usr/bin/podman" "$rc $out"
out="$(ships_config 2>&1)"; rc=$?
check "and without the configuration" "1 the package does not ship /usr/share/containers/policy.json" "$rc $out"

for f in "${ENGINE_FILES[@]}"; do mkdir -p "$(dirname "$GLYNDOR_ROOT$f")"; : > "$GLYNDOR_ROOT$f"; done
out="$(ships_engine 2>&1)"; rc=$?
check "with every file of the engine it is accepted" "0 " "$rc $out"
rm "$GLYNDOR_ROOT/usr/libexec/podman/aardvark-dns"
out="$(ships_engine 2>&1)"; rc=$?
check "one file missing is refused and named" "1 the package does not ship /usr/libexec/podman/aardvark-dns" "$rc $out"

for f in "${CONFIG_FILES[@]}"; do mkdir -p "$(dirname "$GLYNDOR_ROOT$f")"; echo x > "$GLYNDOR_ROOT$f"; done
out="$(ships_config 2>&1)"; rc=$?
check "with every file of the configuration it is accepted" "0 " "$rc $out"
: > "$GLYNDOR_ROOT/usr/share/containers/seccomp.json"
out="$(ships_config 2>&1)"; rc=$?
check "an empty configuration file is refused" "1 the package does not ship /usr/share/containers/seccomp.json" "$rc $out"
check "nothing in either list is under /etc/containers" 0 "$(printf '%s\n' "${ENGINE_FILES[@]}" "${CONFIG_FILES[@]}" | grep -c '^/etc/containers')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
