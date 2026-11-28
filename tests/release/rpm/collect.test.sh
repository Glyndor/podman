#!/usr/bin/env bash
#
# Tests for scripts/release/rpm/collect.sh: the artifacts of the build jobs become the one set of the release only when
# each holds exactly the packages of its leg and each file is the one its build job hashed; the noarch packages come from
# the x86_64 leg; and the hash of the set changes when anything in it does.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/release/rpm/collect.sh"
NAMES="$HERE/scripts/release/rpm/names.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
# shellcheck source=tests/lib/rpm-set.sh
. "$HERE/tests/lib/rpm-set.sh"
small_table "$WORK/distros.txt"

V=6.2.0+r4
LEGS="$(bash "$NAMES" legs)"
# What every leg uploaded, in a directory of its own, and what each reported. The noarch files of each architecture hold
# the architecture, so the set shows which leg they came from.
fresh() {
	rm -rf "$WORK/dl" "$WORK/set" "$WORK/pristine"
	local id arch name hashes json="{"
	if [ -d "$WORK/master" ]; then cp -a "$WORK/master/dl" "$WORK/dl"; cp "$WORK/master/legs.json" "$WORK/legs.json"; return; fi
	mkdir -p "$WORK/dl"
	while read -r id arch; do
		mkdir "$WORK/dl/rpm-$id-$arch"
		hashes=""
		while IFS= read -r name; do
			fake_rpm "$WORK/dl/rpm-$id-$arch/$name" "$name built on $arch"
			hashes+=" $name=$(sha256sum "$WORK/dl/rpm-$id-$arch/$name" | cut -d' ' -f1)"
		done <<< "$(bash "$NAMES" leg "$V" "$id" "$arch")"
		json+="\"${id}_$arch\":\"1 x$hashes\","
	done <<< "$LEGS"
	printf '%s}' "${json%,}" > "$WORK/legs.json"
	mkdir "$WORK/master"; cp -a "$WORK/dl" "$WORK/master/dl"; cp "$WORK/legs.json" "$WORK/master/legs.json"
}
gather() { out="$(bash "$SCRIPT" gather "$V" "${1:-rpm}" "$(cat "$WORK/legs.json")" "$WORK/dl" "$WORK/set" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
staged() { [ -d "$WORK/set" ] && find "$WORK/set" -type f | wc -l || echo 0; }
refused() { check "$1" "1 1 0" "$rc $(says "$2") $(staged)"; }
edit() { jq -c "$1" "$WORK/legs.json" > "$WORK/new" && mv "$WORK/new" "$WORK/legs.json"; }
one=podman-6.2.0+r4-4.glyndor.el9.aarch64.rpm
leg="$WORK/dl/rpm-el9-aarch64"

fresh; gather
check "every leg with its packages, as hashed: the files of the release are gathered" "0 $(bash "$NAMES" release "$V" | sort | paste -sd' ')" \
	"$rc $(find "$WORK/set" -type f -printf '%f\n' | sort | paste -sd' ')"
check "and every noarch package is the one of the x86_64 leg" "6 0" \
	"$(cat "$WORK"/set/*.noarch.rpm | grep -a -c 'built on x86_64') $(cat "$WORK"/set/*.noarch.rpm | grep -a -c 'built on aarch64')"
check "and each architecture's own packages are its own" 1 "$(grep -a -c 'built on aarch64' "$WORK/set/$one")"
digest() { bash "$SCRIPT" digest "$V" "$WORK/set"; }
first="$(digest)"
check "the hash of the set is a sha256" 1 "$(grep -c -x -E '[0-9a-f]{64}' <<< "$first")"
check "the same set gives the same hash" "$first" "$(digest)"
check "and it is the hash of the sha256 lines of the files in the order of the names" \
	"$(cd "$WORK/set" && bash "$NAMES" release "$V" | xargs sha256sum | sha256sum | cut -d' ' -f1)" "$first"
printf x >> "$WORK/set/$one"
check "a file that changes changes the hash" differs "$([ "$(digest)" = "$first" ] && echo same || echo differs)"

fresh; rm "$leg/$one"; gather
refused "a package missing from a leg" "the download is not the expected set"
fresh; rm -r "$leg"; gather
refused "a leg missing whole" "the download is not the expected set"
fresh; fake_rpm "$leg/extra.rpm"; gather
refused "a file of more in a leg" "the download is not the expected set"
fresh; mkdir "$WORK/dl/rpm-fc43-x86_64"; gather
refused "a directory that is no leg" "the download is not the expected set"
fresh; rm "$leg/$one"; ln -s /etc/hostname "$leg/$one"; gather
refused "a link in place of a package" "the download is not the expected set"
fresh; printf x >> "$leg/$one"; gather
refused "a file that is not the one its build hashed" "and the build hashed"
fresh; printf x >> "$WORK/dl/rpm-el9-aarch64/podmansh-6.2.0+r4-4.glyndor.el9.noarch.rpm"; gather
refused "a noarch file of the aarch64 leg that changed, though the release takes the other" "and the build hashed"
fresh; edit ".el9_aarch64 |= (split(\" \") | map(select(startswith(\"$one=\") | not)) | join(\" \"))"; gather
refused "a report that does not hash one of the packages" "did not report one hash for each of its packages"
fresh; edit '.el9_aarch64 += " other.rpm=aaaa"'; gather
refused "a report that hashes a file that is no package of the leg" "did not report one hash for each of its packages"
fresh; edit '.el9_aarch64 |= sub("el9[.]aarch64[.]rpm=[0-9a-f]+"; "el9.aarch64.rpm=zz")'; gather
refused "a hash that is no sha256" "not a sha256"
fresh; edit 'del(.el9_aarch64)'; gather
refused "a leg that reported nothing" "the leg el9_aarch64 reported nothing"
fresh; truncate -s 301M "$leg/$one"; gather
refused "a package over the cap" "is over the size cap"
fresh; gather rpmcheck
refused "the artifacts of a release read as a check's" "the download is not the expected set"
fresh; gather deb
refused "another prefix" "not 'deb-'"
fresh; mkdir "$WORK/set"; : > "$WORK/set/old"; gather
check "a set directory with something in it" "1 1" "$rc $(says 'is not an empty directory')"
fresh; mkdir -p "$WORK/real"; ln -s "$WORK/real" "$WORK/set"; gather
check "a set that is a link" "1 1" "$rc $(says 'is not an empty directory')"
rm -f "$WORK/set"; fresh; rm -r "$WORK/dl"; gather
check "no download" "1 1" "$rc $(says 'is not a directory')"
fresh; out="$(GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" gather "$V" rpm '{}' "$WORK/dl" "$WORK/set" 2>&1)"; rc=$?
check "legs that cannot be read" "1 1" "$rc $(says 'the legs of distros.txt cannot be read')"
out="$(bash "$SCRIPT" gather 6.2 rpm '{}' "$WORK/dl" "$WORK/set" 2>&1)"; rc=$?
check "a version that names nothing" "1 1" "$rc $(says 'cannot be named')"

fresh; gather
set_digest() { out="$(bash "$SCRIPT" digest "${1:-$V}" "$WORK/set" 2>&1)"; rc=$?; }
rm "$WORK/set/$one"; set_digest
check "a set that lacks a package has no hash" "1 1" "$rc $(says 'is not the expected one')"
fresh; gather; fake_rpm "$WORK/set/extra.rpm"; set_digest
check "nor one with a file of more" "1 1" "$rc $(says 'is not the expected one')"
fresh; gather; rm "$WORK/set/$one"; ln -s /etc/hostname "$WORK/set/$one"; set_digest
check "nor one with a link in it" 1 "$rc"
fresh; set_digest
check "nor a set that is not there" "1 1" "$rc $(says 'is not a directory')"
fresh; gather; set_digest 6.2
check "nor a version that names nothing" "1 1" "$rc $(says 'cannot be named')"

bash "$SCRIPT" > /dev/null 2>&1; check "no arguments is a usage error" 2 "$?"
bash "$SCRIPT" gather "$V" > /dev/null 2>&1; check "gather with too few arguments is a usage error" 2 "$?"
bash "$SCRIPT" digest "$V" > /dev/null 2>&1; check "digest with too few arguments is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
