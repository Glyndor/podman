#!/usr/bin/env bash
#
# Tests for scripts/package/distros.sh and the table it reads: a row says what the contract
# says, a malformed table is refused, the matrix has one entry for every distribution and
# architecture, and every id of the table has the image it is built in, pinned by digest.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/package/distros.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
table() { GLYNDOR_DISTROS_FILE="$WORK/t" bash "$SCRIPT" "$@" 2>&1; }

# --- the table as committed ---------------------------------------------------------
check "the epoch of fc45 is the one Fedora's own podman has" 5 "$(bash "$SCRIPT" field fc45 epoch)"
check "the family of fc44" fedora "$(bash "$SCRIPT" field fc44 family)"
check "an id the table does not have is refused" "unknown distribution: nope" "$(bash "$SCRIPT" field nope epoch 2>&1)"
check "a column it does not have is refused" "unknown column: colour" "$(bash "$SCRIPT" field fc45 colour 2>&1)"
check "a row with no images to test on has an empty value, not an error" "0 " "$(bash "$SCRIPT" field fc45 tests > "$WORK/v" 2>&1; echo "$? $(cat "$WORK/v")")"
check "every id is a format of the contract" "" "$(for id in $(bash "$SCRIPT" ids rpm) $(bash "$SCRIPT" ids pacman); do bash "$SCRIPT" field "$id" format | grep -v -x -e rpm -e pacman; done)"

# Every id has the image it is built in, every image is pinned to a digest, and every runner the
# matrix hands out is a label the workflows name.
for id in $(bash "$SCRIPT" ids rpm) $(bash "$SCRIPT" ids pacman); do
	file="$HERE/scripts/package/images/$id/Dockerfile"
	check "$id has its image" 1 "$([ -f "$file" ] && echo 1 || echo 0)"
	check "$id's image is one FROM, a release tag and a sha256 digest" 1 \
		"$(grep -c -E '^FROM [a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' "$file")"
	check "$id's image has no other instruction" 0 "$(grep -v -e '^#' -e '^$' -e '^FROM ' "$file" | wc -l | tr -d ' ')"
done
for dir in "$HERE"/scripts/package/images/*/; do
	name="$(basename "$dir")"
	known=0
	for id in $(bash "$SCRIPT" ids rpm) $(bash "$SCRIPT" ids pacman); do
		[ "$id" = "$name" ] && known=1
		for t in $(bash "$SCRIPT" field "$id" tests | tr ',' ' '); do [ "$t" = "$name" ] && known=1; done
	done
	check "the image $name belongs to a row of the table" 1 "$known"
done
check "the runners of the matrix are the ones the workflows name" "ubuntu-24.04 ubuntu-24.04-arm" \
	"$(bash "$SCRIPT" matrix rpm all | grep -o '"runner":"[^"]*"' | cut -d'"' -f4 | sort -u | paste -sd' ')"

# --- the matrix ------------------------------------------------------------------------
cat > "$WORK/t" <<'T'
# a comment
a1|rpm|fedora|x86_64,aarch64|5|2|5|upstream|0^20260716|
b2|rpm|suse|x86_64|0|0|0|upstream|20260716|imgone,imgtwo
c3|pacman|arch|x86_64|0|0|1|upstream|20260716|
T
check "ids of a format, in table order" "a1 b2" "$(table ids rpm | paste -sd' ')"
check "every architecture of every row of the format" \
	'[{"id":"a1","family":"fedora","arch":"x86_64","runner":"ubuntu-24.04"},{"id":"a1","family":"fedora","arch":"aarch64","runner":"ubuntu-24.04-arm"},{"id":"b2","family":"suse","arch":"x86_64","runner":"ubuntu-24.04"}]' \
	"$(table matrix rpm all)"
check "one architecture leaves out the rows that do not build there" '[{"id":"a1","family":"fedora","arch":"aarch64","runner":"ubuntu-24.04-arm"}]' "$(table matrix rpm aarch64)"
check "a format with no row is an empty list" "[]" "$(table matrix nothing all)"
check "an unknown architecture is a usage error" "unknown architectures: riscv" "$(table matrix rpm riscv)"
check "the list of images to test on" "imgone,imgtwo" "$(table field b2 tests)"

# --- a malformed table ------------------------------------------------------------------
bad() { # <desc> <line> <what it says>
	printf '%s\n' "$2" > "$WORK/t"
	check "$1" "$3" "$(table ids rpm | tail -n 1)"
}
bad "a row with a field too few" 'a1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716' "distros.txt is malformed"
bad "an id with a capital" 'A1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an id with a character a file name or a shell would read" 'a-1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "a format that is neither rpm nor pacman" 'a1|deb|fedora|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an unknown family" 'a1|rpm|gentoo|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an unknown architecture" 'a1|rpm|fedora|riscv64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an epoch that is not a number" 'a1|rpm|fedora|x86_64|five|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an unknown containers-common scheme" 'a1|rpm|fedora|x86_64|5|2|5|dated|0^20260716|' "distros.txt is malformed"
bad "a passt version that is not one" 'a1|rpm|fedora|x86_64|5|2|5|upstream|new|' "distros.txt is malformed"
bad "a test image with a character a shell would read" 'a1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|img;rm' "distros.txt is malformed"
printf 'a1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|\na1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|\n' > "$WORK/t"
check "an id twice" "distros.txt is malformed" "$(table ids rpm | tail -n 1)"
out="$(GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" ids rpm 2>&1)"; check "a table that is not there" "1" "$?"
check "and it says so" "no distribution table at $WORK/absent" "$out"
bash "$SCRIPT" > /dev/null 2>&1; check "no command is a usage error" 2 "$?"
check "and it says how to call it" 1 "$(bash "$SCRIPT" 2>&1 | grep -c "usage: distros.sh field")"
bash "$SCRIPT" field fc45 > /dev/null 2>&1; check "field without a column is a usage error" 2 "$?"
bash "$SCRIPT" ids > /dev/null 2>&1; check "ids without a format is a usage error" 2 "$?"
bash "$SCRIPT" matrix rpm > /dev/null 2>&1; check "matrix without architectures is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
