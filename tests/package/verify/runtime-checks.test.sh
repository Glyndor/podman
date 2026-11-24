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
	"no pasta is left running after the last container stopped, waited for ten seconds at most"; do
	check "the check '$name' is there" 1 "$(grep -c -F -- "\"$name\"" "$LIB")"
done
check "it defines nothing that runs on its own: no exit of its own" 0 "$(grep -c '^exit' "$LIB")"
for user in rpm-test pacman-test; do
	file="$HERE/scripts/package/verify/$user.sh"
	[ -f "$file" ] || continue
	check "$user.sh sources it" 1 "$(grep -c '^\. "\$here/runtime-checks.sh"' "$file")"
done

# --- the wait for the last pasta, run with a clock the test moves: it says how long it really waited ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sed -n '/^pasta_gone() {/,/^}/p' "$LIB" > "$WORK/pasta_gone.sh"
check "the function of the wait is found in the lib" 1 "$(grep -c '^pasta_gone() {' "$WORK/pasta_gone.sh")"
# A sleep that only moves the clock, and a date that reads it, so ten seconds take no time and the numbers are exact.
run_wait() { # <polls before the pasta goes: 0 none, 99 never> -> its output and exit status
	(
		clock=0; polls=0; keep="$1"; real=
		date() { echo "$clock"; }
		sleep() { clock=$((clock + 200000000)); polls=$((polls + 1)); }
		pasta_pids() { if [ "$keep" -ne 0 ] && [ "$polls" -lt "$keep" ]; then echo "$real"; fi; }
		rl() { echo "state of the user: $*"; }
		command sleep 60 &
		real=$!
		# shellcheck disable=SC1091
		. "$WORK/pasta_gone.sh"
		pasta_gone; rc=$?
		kill "$real" 2> /dev/null
		echo "rc=$rc"
	) 2>&1
}
out="$(run_wait 0)"
check "with no pasta left it says so, and that it waited nothing" "no pasta was left after waiting 0.000 s rc=0" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
out="$(run_wait 3)"
check "with a pasta that goes after three polls it says it waited 0.600 s" "no pasta was left after waiting 0.600 s rc=0" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
out="$(run_wait 99)"
check "with a pasta that stays it says it waited the ten seconds and fails" "1 1" "$(printf '%s\n' "$out" | grep -c 'rc=1') $(printf '%s\n' "$out" | grep -c 'pasta is still running after waiting 10.000 s, the whole ten seconds')"
check "and it shows the command line of the process" 1 "$(printf '%s\n' "$out" | grep -c 'sleep 60')"
check "and its parent" 1 "$(printf '%s\n' "$out" | grep -c '^  parent: ')"
check "and its network namespace and the containers of the user" "1 1" "$(printf '%s\n' "$out" | grep -c '^  network namespace ') $(printf '%s\n' "$out" | grep -c '^state of the user: state')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
