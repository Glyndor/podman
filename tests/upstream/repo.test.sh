#!/usr/bin/env bash
#
# Tests for scripts/upstream/repo.sh: where each upstream component lives, and that anything else is refused.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/repo.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

check "podman is where it lives now" "podman-container-tools/podman" "$(bash "$SCRIPT" podman)"
check "netavark is under containers" "containers/netavark" "$(bash "$SCRIPT" netavark)"
check "aardvark-dns is under containers" "containers/aardvark-dns" "$(bash "$SCRIPT" aardvark-dns)"
out="$(bash "$SCRIPT" buildah 2>&1)"; rc=$?
check "another component is refused" "2" "$rc"
check "and the refusal names it" "unknown upstream component: buildah" "$out"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
check "no component is refused" "2 unknown upstream component: " "$rc $out"
check "latest-stable.sh asks the same place as repo.sh, by default" "1" "$(grep -c "https://github.com/$(bash "$SCRIPT" podman).git" "$HERE/scripts/upstream/latest-stable.sh")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
