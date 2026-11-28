#!/usr/bin/env bash
#
# Tests for scripts/release/rpm/names.sh: the exact names of the rpm packages of a release, from the version and the
# tables of scripts/package. The names are written out here for the table the repository commits, so a row added or a
# name that changes shows up, and every way a table or an argument cannot give them is refused.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/release/rpm/names.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
run() { out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

run legs
check "the legs are every rpm row and architecture of the table, fourteen today" "0 14" "$rc $(grep -c . <<< "$out")"
check "in the order of the table" "fc45 x86_64|fc45 aarch64|fc44 x86_64" "$(head -n 3 <<< "$out" | paste -sd'|')"

run leg 6.2.1+r6 fc45 x86_64
check "a distribution with nothing beside it: podman for its architecture and the two noarch packages" \
	"0 podman-6.2.1+r6-6.glyndor.fc45.x86_64.rpm|podman-docker-6.2.1+r6-6.glyndor.fc45.noarch.rpm|podmansh-6.2.1+r6-6.glyndor.fc45.noarch.rpm" "$rc $(paste -sd'|' <<< "$out")"
run leg 6.2.1+r6 amzn2023 aarch64
check "a distribution that takes dependencies beside it: each with its own version, from extras.txt" \
	"0 podman-6.2.1+r6-6.glyndor.amzn2023.aarch64.rpm|crun-1.31-6.glyndor.amzn2023.aarch64.rpm|conmon-2.2.1-6.glyndor.amzn2023.aarch64.rpm|catatonit-0.2.1-6.glyndor.amzn2023.aarch64.rpm|podman-docker-6.2.1+r6-6.glyndor.amzn2023.noarch.rpm|podmansh-6.2.1+r6-6.glyndor.amzn2023.noarch.rpm" \
	"$rc $(paste -sd'|' <<< "$out")"

run release 6.2.1+r6
check "the release: forty files" "0 40" "$rc $(grep -c . <<< "$out")"
check "podman for each of the fourteen legs" 14 "$(grep -c '^podman-[0-9]' <<< "$out")"
check "each noarch package once for each of the seven distributions" "7 7" "$(grep -c '^podman-docker-.*noarch\.rpm$' <<< "$out") $(grep -c '^podmansh-.*noarch\.rpm$' <<< "$out")"
check "and twelve packages of the dependencies beside them" 12 "$(grep -c -E '^(crun|conmon|catatonit|passt)-' <<< "$out")"
check "no name twice" 40 "$(sort -u <<< "$out" | grep -c .)"
check "every name ends in the revision and a distribution of the table" 40 \
	"$(grep -c -E -- '-6\.glyndor\.(fc45|fc44|el10|tumbleweed|el9|amzn2023|leap161)\.(x86_64|aarch64|noarch)\.rpm$' <<< "$out")"
check "the release is every leg's files, with the noarch ones once" \
	"$(while read -r id arch; do bash "$SCRIPT" leg 6.2.1+r6 "$id" "$arch"; done <<< "$(bash "$SCRIPT" legs)" | sort -u)" "$(sort <<< "$out")"

run release 6.2.1
check "the first build of a Podman version carries revision 1 in the names" "0 40" "$rc $(grep -c -- '-1\.glyndor\.' <<< "$out")"
check "and the version with its revision written" 1 "$(grep -c -x 'podman-6.2.1+r1-1.glyndor.fc45.x86_64.rpm' <<< "$out")"
run leg 6.2.1 el9 x86_64
check "a dependency keeps its own version whatever the release is" 1 "$(grep -c -x 'catatonit-0.2.1-1.glyndor.el9.x86_64.rpm' <<< "$out")"

# --- what cannot be named --------------------------------------------------------------------
for bad in "" v6.2.1 6.2 '6.2.1+r0' '6.2.1; x'; do
	run release "$bad"
	check "the version '$bad' names nothing" "1 0" "$rc $(grep -c '\.rpm$' <<< "$out")"
done
run leg 6.2.1 fc43 x86_64
check "a distribution that is not in the table names nothing" "1 0" "$rc $(grep -c '\.rpm$' <<< "$out")"
run leg 6.2.1 fc45 s390x
check "an architecture the row does not build names nothing" "1 1" "$rc $(says 'is not built for s390x')"

table() { printf '%s\n' "$@" > "$WORK/distros.txt"; }
row_x86='one|rpm|fedora|x86_64,aarch64|0|0|0|upstream|20260716||'
tabled() { out="$(GLYNDOR_DISTROS_FILE="$WORK/distros.txt" GLYNDOR_EXTRAS_FILE="${EXTRAS:-$HERE/scripts/package/extras.txt}" bash "$SCRIPT" "$@" 2>&1)"; rc=$?; }
table "$row_x86"
tabled release 6.2.1
check "a table of one row names that row's files" "0 4" "$rc $(grep -c '\.rpm$' <<< "$out")"
table 'arch|pacman|arch|x86_64|0|0|0|upstream|20260716||'
tabled leg 6.2.1 arch x86_64
check "a pacman row is not an rpm distribution" "1 1" "$rc $(says 'is not an rpm distribution')"
tabled release 6.2.1
check "a table with no rpm row names no release" "1 1" "$rc $(says 'has no rpm row')"
tabled legs
check "nor any leg" "1 1" "$rc $(says 'has no rpm row')"
table 'arm|rpm|fedora|aarch64|0|0|0|upstream|20260716||'
tabled release 6.2.1
check "a row with no x86_64 has nowhere to take the noarch packages from" "1 1" "$rc $(says 'the leg the noarch packages come from')"
table 'broken|rpm'
tabled release 6.2.1
check "a table that cannot be read names nothing" "1 0" "$rc $(grep -c '\.rpm$' <<< "$out")"
tabled legs
check "and no leg" 1 "$rc"

table 'one|rpm|el|x86_64|0|0|0|upstream|20260716||crun'
grep -v '^crun|' "$HERE/scripts/package/extras.txt" > "$WORK/none.txt"
EXTRAS="$WORK/none.txt" tabled leg 6.2.1 one x86_64
check "a dependency extras.txt does not pin is refused" "1 1" "$rc $(says 'pins no single version for crun')"
EXTRAS="$WORK/none.txt" tabled release 6.2.1
check "and so is the release that would carry it" 1 "$rc"
{ grep '^crun|' "$HERE/scripts/package/extras.txt"; grep '^crun|' "$HERE/scripts/package/extras.txt"; } > "$WORK/twice.txt"
EXTRAS="$WORK/twice.txt" tabled leg 6.2.1 one x86_64
check "a dependency pinned twice is refused" "1 1" "$rc $(says 'pins no single version for crun')"
EXTRAS="$WORK/absent.txt" tabled leg 6.2.1 one x86_64
check "no extras table at all is refused" "1 1" "$rc $(says 'is missing')"

# --- usage -----------------------------------------------------------------------------------
for args in "" "legs x" "leg 6.2.1" "release" "other"; do
	# shellcheck disable=SC2086 # the words are the arguments
	run $args
	check "'$args' is a usage error" 2 "$rc"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
