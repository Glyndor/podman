#!/usr/bin/env bash
#
# Tests for scripts/quality/mutation-scope.sh, the decision of which entries of the
# mutation catalogue a pull request runs. It runs in a throwaway repository with a
# catalogue of three entries over two scripts and their suites, and each case is a
# pull request made on top of the same base: the entries a change can affect are
# selected and no other, and every way the decision can go wrong runs them all.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/quality/mutation-scope.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

R="$WORK/repo"
g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false "$@"; }
mkdir -p "$R/scripts/area" "$R/tests/area" "$R/tests/mutation" "$R/tests/lib" "$R/docs"
printf '#!/bin/sh\n[ -n "$1" ] || exit 1\n' > "$R/scripts/area/one.sh"
printf '#!/bin/sh\n[ -f "$1" ] || exit 2\n' > "$R/scripts/area/two.sh"
printf '#!/bin/sh\n[ -d "$1" ] || exit 3\n' > "$R/scripts/area/three.sh"
# The suite of one.sh also runs helper.sh, by name; the suite of two.sh reads nothing else.
printf '#!/bin/sh\nsh scripts/area/one.sh x && sh scripts/area/helper.sh\n' > "$R/tests/area/one.test.sh"
printf '#!/bin/sh\nsh scripts/area/two.sh /\n' > "$R/tests/area/two.test.sh"
printf '#!/bin/sh\nsh scripts/area/three.sh /\n' > "$R/tests/area/three.test.sh"
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/area/helper.sh"
printf '# a helper the suites source\n' > "$R/tests/lib/common.sh"
printf 'notes\n' > "$R/docs/notes.md"
entry() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
{
	echo "# the catalogue"
	entry one-empty scripts/area/one.sh '[ -n "$1" ] || exit 1' 'true' tests/area/one.test.sh
	entry two-missing scripts/area/two.sh '[ -f "$1" ] || exit 2' 'true' tests/area/two.test.sh
	entry three-missing scripts/area/three.sh '[ -d "$1" ] || exit 3' 'true' tests/area/three.test.sh
} > "$R/tests/mutation/catalog.txt"
cp "$SCRIPT" "$R/scripts/area/mutation-scope.sh"
g init -q; g add -A; g commit -q -m base
base="$(g rev-parse HEAD)"
# The base of the cases of the split catalogue, which need one of their own.
base0="$base"

pr() { # <message> <command...>: a pull request on top of the base, checked out; sets $head
	g checkout -q -B pr "$base"
	(cd "$R" && "${@:2}")
	g add -A; g commit -q -m "$1"; head="$(g rev-parse HEAD)"
}
decide() { # [EVENT]: sets $out (the ids, space separated) and $rc
	rc=0
	out="$(cd "$R" && EVENT="${1:-pull_request}" BASE="$base" HEAD="$head" bash "$SCRIPT" 2>"$WORK/err" | paste -sd' ')" || rc=$?
}

pr "docs only" sh -c 'echo more >> docs/notes.md'
decide
check "a change to docs affects no entry: nothing is printed" "0 " "$rc $out"
decide push
check "any event but a pull request runs every entry" "0 all" "$rc $out"
check "and says why" 1 "$(grep -c 'not a pull request' "$WORK/err")"

pr "a guarded script" sh -c 'echo "# changed" >> scripts/area/two.sh'
decide
check "a change to a guarded script selects its entries and no other" "0 two-missing" "$rc $out"
pr "a suite" sh -c 'echo "# changed" >> tests/area/three.test.sh'
decide
check "a change to a suite selects the entries that name it" "0 three-missing" "$rc $out"
pr "what a suite runs" sh -c 'echo "# changed" >> scripts/area/helper.sh'
decide
check "a change to a script a suite names selects that suite's entries" "0 one-empty" "$rc $out"
pr "an entry" sh -c "sed -i 's/	true	tests\/area\/two.test.sh/	exit 0	tests\/area\/two.test.sh/' tests/mutation/catalog.txt"
decide
check "a changed line of the catalogue selects that entry" "0 two-missing" "$rc $out"
pr "an exemption" sh -c 'printf "scripts/area/one.sh\t*\ta reason\n" > tests/mutation/exemptions.txt'
decide
check "a change to the exemptions, which the sweep does not read, affects no entry" "0 " "$rc $out"
pr "two scripts and a suite" sh -c 'echo "# x" >> scripts/area/one.sh; echo "# x" >> scripts/area/two.sh; echo "# x" >> tests/area/three.test.sh'
decide
check "when every entry is selected it says all" "0 all" "$rc $out"

# --- every way it can go wrong runs them all ----------------------------------------
for f in tests/lib/common.sh tests/mutation/run-mutations.sh scripts/quality/mutation-scope.sh .github/workflows/mutation.yml; do
	pr "touches $f" sh -c "mkdir -p '$(dirname "$f")' && echo '# x' >> '$f'"
	decide
	check "a change to $f runs every entry" "0 all" "$rc $out"
done
pr "a fixture" sh -c 'mkdir -p tests/area/fixtures && echo data > tests/area/fixtures/vector.bin'
decide
check "a file under tests/ that is not a suite runs every entry" "0 all" "$rc $out"
pr "a broken catalogue" sh -c 'printf "one-empty\tscripts/area/one.sh\n" >> tests/mutation/catalog.txt'
decide
check "a catalogue it cannot read runs every entry" "0 all" "$rc $out"
pr "a repeated id" sh -c 'printf "two-missing\tscripts/area/two.sh\tx\ty\ttests/area/two.test.sh\n" >> tests/mutation/catalog.txt'
decide
check "a catalogue with an id twice runs every entry" "0 all" "$rc $out"
pr "docs only" sh -c 'echo more >> docs/notes.md'
base=0000000000000000000000000000000000000000
decide
check "a base it cannot read runs every entry" "0 all" "$rc $out"
check "and says it could not narrow the sweep" 1 "$(grep -c 'Cannot narrow the mutation sweep' "$WORK/err")"
base="$head"
decide
check "an empty diff runs every entry" "0 all" "$rc $out"

# --- the catalogue is two files ----------------------------------------------------------
#
# The entries of an area live in the file that names it, and the two are one
# catalogue with one set of ids.

# A new entry in the second file of the catalogue is an entry of the catalogue.
base="$base0"
pr "a new entry in the second catalogue" sh -c 'printf "four-missing\tscripts/area/four.sh\told\tnew\ttests/area/four.test.sh\n" > tests/mutation/catalog-tests.txt'
decide
check "a new entry in the second catalogue decides that entry" "0 four-missing" "$rc $out"

# An id in both files is an id twice, and the catalogue cannot be read.
pr "an id in both catalogues" sh -c 'printf "one-empty\tscripts/area/one.sh\told\tnew\ttests/area/one.test.sh\n" > tests/mutation/catalog-tests.txt'
decide
check "an id in both catalogues runs every entry" "0 all" "$rc $out"
check "and says a line of the catalogue cannot be read" 1 "$(grep -c 'a line of the catalogue' "$WORK/err")"

# An entry that moves from one file to the other is still in the catalogue.
pr "an entry that moves" sh -c "grep '^three-missing' tests/mutation/catalog.txt > tests/mutation/catalog-tests.txt; sed -i '/^three-missing/d' tests/mutation/catalog.txt"
decide
check "an entry that moves between the files affects no entry" "0 " "$rc $out"

# A pull request that takes an entry away decides nothing: the entry it removes
# selects nothing, and the sweep would be skipped as if that had been decided.
pr "an entry and its exemption" sh -c 'sed -i "/^three-missing/d" tests/mutation/catalog.txt; printf "scripts/area/three.sh\t*\ta reason\n" > tests/mutation/exemptions.txt'
decide
check "a pull request that takes an entry away runs every entry" "0 all" "$rc $out"
check "and names the entry" 1 "$(grep -c 'takes an entry of the catalogue away: three-missing$' "$WORK/err")"

# The same when what goes is a whole file of the catalogue.
pr "the second catalogue" sh -c 'printf "four-missing\tscripts/area/four.sh\told\tnew\ttests/area/four.test.sh\n" > tests/mutation/catalog-tests.txt'
base="$(g rev-parse HEAD)"
pr "the second catalogue is gone" sh -c 'rm tests/mutation/catalog-tests.txt'
decide
check "a pull request that deletes a file of the catalogue runs every entry" "0 all" "$rc $out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
