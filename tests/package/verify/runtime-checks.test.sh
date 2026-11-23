#!/usr/bin/env bash
#
# Tests for scripts/package/verify/runtime-checks.sh as far as a stand-in reaches. It is the part
# of the proof of a native package that starts containers, which needs a machine of the
# distribution with the package installed; its real run is the one of rpm-test.sh and
# pacman-test.sh in the workflow. What is held here is that it parses, that it is sourced and not
# run, and that the checks of the proof are all still in it by name.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$HERE/scripts/package/verify/runtime-checks.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

bash -n "$LIB"; check "the file parses" 0 "$?"
for name in \
	"a container runs as root" \
	"a container resolves another by name on a bridge network (netavark and aardvark-dns), root" \
	"an unprivileged user can map ids and Podman can create its namespace" \
	"a container runs on pasta, rootless" \
	"a rootless container reaches the host through pasta" \
	"a rootless container resolves another by name on a bridge network" \
	"the last container of a rootless bridge network stops through the API" \
	"no pasta is left running after the last container stopped"; do
	check "the check '$name' is there" 1 "$(grep -c -F -- "\"$name\"" "$LIB")"
done
check "it defines nothing that runs on its own: no exit of its own" 0 "$(grep -c '^exit' "$LIB")"
for user in rpm-test pacman-test; do
	file="$HERE/scripts/package/verify/$user.sh"
	[ -f "$file" ] || continue
	check "$user.sh sources it" 1 "$(grep -c '^\. "\$here/runtime-checks.sh"' "$file")"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
