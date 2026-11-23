#!/usr/bin/env bash
#
# Tests for scripts/package/verify/engine-files.sh: the two lists of what a customer expects on disk after a native
# package of Podman is installed. The files are absolute paths of an installed system, so what is held here is what
# the lists name and that a machine that has none of them is refused with the first one named.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$HERE/scripts/package/verify/engine-files.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=scripts/package/verify/engine-files.sh
. "$LIB"
err="$(ships_engine 2>&1 > /dev/null)"; rc=$?
if [ -e /usr/bin/podman ] && [ -e /usr/libexec/podman/netavark ]; then
	check "on a machine with Podman installed the engine list is read" "ok" "ok"
else
	check "a machine without the engine is refused" 1 "$rc"
	check "and the first file it lacks is named" "the package does not ship /usr/bin/podman" "$err"
fi
check "the engine list names the binaries, the helpers, the units and the completions" "4" \
	"$(grep -c -e '/usr/bin/podman' -e 'netavark' -e 'podman.socket' -e 'bash-completion' "$LIB")"
check "the configuration list is all under /usr/share/containers" 0 "$(sed -n '/^ships_config/,/^}/p' "$LIB" | grep -o '/[a-z/.0-9-]*' | grep -v -e '^/usr/share/containers' | grep -c -e '/etc/')"
check "and nothing in either list is under /etc/containers" 0 "$(grep -v '^#' "$LIB" | grep -c '/etc/containers')"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
