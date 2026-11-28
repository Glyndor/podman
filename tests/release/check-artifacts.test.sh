#!/usr/bin/env bash
#
# Tests for scripts/release/check-artifacts.sh: the set a release job downloaded has to be
# exactly the one the verified tag names, and whatever else comes with it, or whatever is
# not what it says, is refused before a key is read. Real .deb files are built here, tiny
# ones, so the control file the script reads is a real one, and the rpm packages are fakes
# that start as an rpm does, one for every name of scripts/release/rpm/names.sh.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/release/check-artifacts.sh"
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

mkdeb() { # <path> <package> <version> <arch>
	local root="$WORK/root-$$-$RANDOM"
	mkdir -p "$root/DEBIAN"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: x <x@example.org>\nDescription: x\n' "$2" "$3" "$4" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group -Znone --build "$root" "$1" > /dev/null
	rm -rf "$root"
}

# fresh <version>: a download of both architectures as the workflow lays it out.
fresh() {
	rm -rf "$WORK/in" "$WORK/out"
	mkdir -p "$WORK/in/deb-amd64" "$WORK/in/deb-arm64"
	mkdeb "$WORK/in/deb-amd64/podman_$1_amd64.deb" podman "$1" amd64
	mkdeb "$WORK/in/deb-arm64/podman_$1_arm64.deb" podman "$1" arm64
	fake_rpms "$WORK/in/rpm" "$1"
}
built() { out="$(bash "$SCRIPT" built "${1:-v6.2.0+r12}" "$WORK/in" "$WORK/out" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

fresh 6.2.0+r12
built
check "the exact set passes" 0 "$rc"
check "and every package is copied flat, by name, and nothing else" \
	"$( { printf 'podman_6.2.0+r12_amd64.deb\npodman_6.2.0+r12_arm64.deb\n'; rpm_names 6.2.0+r12; } | LC_ALL=C sort | paste -sd' ')" \
	"$(cd "$WORK/out" && find . -type f -printf '%P\n' | LC_ALL=C sort | paste -sd' ')"
check "which are the two .deb and the fourteen rpm packages of three distributions" 16 "$(find "$WORK/out" -type f | wc -l)"

fresh 6.2.0
built v6.2.0
check "a tag without a revision names its packages without one" 0 "$rc"

# --- what the names are derived from -------------------------------------------------
for bad in 'v6.2.0+r12; x' 'main' 'v6.2' 'V6.2.0' 'v6.2.0+r' '../v6.2.0' 'v6.2.0+r12
x'; do
	fresh 6.2.0+r12
	built "$bad"
	check "a tag that is not a version ($(printf '%s' "$bad" | head -n 1)) is refused" "1 1" "$rc $(says 'is not vX.Y.Z or vX.Y.Z+rN')"
done

# --- more than was built -------------------------------------------------------------
fresh 6.2.0+r12
echo x > "$WORK/in/deb-amd64/venv.py"
built
check "a venv.py planted in an artifact is refused" "1 1" "$rc $(says 'not exactly the expected set')"
check "and nothing is copied" 0 "$([ -e "$WORK/out" ] && ls -A "$WORK/out" | wc -l || echo 0)"
fresh 6.2.0+r12
echo x > "$WORK/in/deb-arm64/pip.py"
built
check "and so is a pip.py" "1" "$rc"
fresh 6.2.0+r12
mkdir "$WORK/in/deb-amd64/pip"
built
check "a directory in an artifact is refused" "1" "$rc"
fresh 6.2.0+r12
mkdir "$WORK/in/deb-extra"
built
check "an artifact that was not asked for is refused" "1" "$rc"
fresh 6.2.0+r12
echo x > "$WORK/in/venv.py"
built
check "a file beside the artifacts is refused" "1" "$rc"
fresh 6.2.0+r12
mkdeb "$WORK/in/deb-amd64/podman_6.2.0+r12_arm64.deb" podman 6.2.0+r12 arm64
built
check "two packages in one artifact, one of the other architecture, are refused" "1" "$rc"
fresh 6.2.0+r12
mkdeb "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb.orig" podman 6.2.0+r12 amd64
built
check "a second file of the same architecture is refused" "1" "$rc"

# --- not what it should be -----------------------------------------------------------
fresh 6.2.0+r12
rm "$WORK/in/deb-arm64/podman_6.2.0+r12_arm64.deb"
built
check "a missing architecture is refused" "1" "$rc"
fresh 6.2.0+r11
built
check "packages of another version are refused" "1 1" "$rc $(says 'not exactly the expected set')"
fresh 6.2.0+r12
mkdeb "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb" podman 6.2.0+r11 amd64
built
check "a file named for this version whose control file says another is refused" "1 1" "$rc $(says 'and not podman 6.2.0+r12 amd64')"
fresh 6.2.0+r12
mkdeb "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb" podman 6.2.0+r12 arm64
built
check "an amd64 name over an arm64 package is refused" "1 1" "$rc $(says 'and not podman 6.2.0+r12 amd64')"
fresh 6.2.0+r12
mkdeb "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb" other 6.2.0+r12 amd64
built
check "another package name is refused" "1 1" "$rc $(says 'and not podman 6.2.0+r12 amd64')"
fresh 6.2.0+r12
echo not-a-deb > "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb"
built
check "a file that is not a package is refused" "1 1" "$rc $(says 'has no readable control file')"

# --- the rpm packages ----------------------------------------------------------------
one=podman-6.2.0+r12-12.glyndor.fc45.x86_64.rpm
fresh 6.2.0+r12
rm "$WORK/in/rpm/$one"
built
check "one rpm package missing is refused" "1 1" "$rc $(says 'not exactly the expected set')"
check "and nothing is copied" 0 "$([ -e "$WORK/out" ] && ls -A "$WORK/out" | wc -l || echo 0)"
fresh 6.2.0+r12
rm "$WORK"/in/rpm/*.glyndor.fc44.*
built
check "a whole distribution missing is refused" "1 1" "$rc $(says 'not exactly the expected set')"
fresh 6.2.0+r12
rm "$WORK/in/rpm/catatonit-0.2.1-12.glyndor.el9.aarch64.rpm"
built
check "a dependency packaged beside podman that is missing is refused" 1 "$rc"
fresh 6.2.0+r12
rm -r "$WORK/in/rpm"
built
check "no rpm packages at all is refused" 1 "$rc"
fresh 6.2.0+r12
fake_rpm "$WORK/in/rpm/podman-6.2.0+r12-12.glyndor.fc43.x86_64.rpm"
built
check "a package of more is refused" "1 1" "$rc $(says 'not exactly the expected set')"
fresh 6.2.0+r12
mv "$WORK/in/rpm/$one" "$WORK/in/rpm/podman-6.2.0+r11-11.glyndor.fc45.x86_64.rpm"
built
check "a package of another revision in place of one is refused" 1 "$rc"
fresh 6.2.0+r12
printf 'not an rpm\n' > "$WORK/in/rpm/$one"
built
check "a file that does not start as an rpm package is refused" "1 1" "$rc $(says 'does not start with the lead of an rpm package')"
fresh 6.2.0+r12
rm "$WORK/in/rpm/$one"; ln -s "$WORK/in/rpm/podman-6.2.0+r12-12.glyndor.fc44.x86_64.rpm" "$WORK/in/rpm/$one"
built
check "a link where an rpm package should be is refused" 1 "$rc"
fresh 6.2.0+r12
truncate -s 301M "$WORK/in/rpm/$one"
built
check "an rpm package over the cap is refused" "1 1" "$rc $(says 'over the size cap')"
fresh 6.2.0+r12
GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" built v6.2.0+r12 "$WORK/in" "$WORK/out" > "$WORK/log" 2>&1; rc=$?
check "packages that cannot be named are refused" "1 1" "$rc $(grep -c 'cannot be named' "$WORK/log")"

# --- links and other types -----------------------------------------------------------
fresh 6.2.0+r12
rm "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb"
ln -s "$WORK/in/deb-arm64/podman_6.2.0+r12_arm64.deb" "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb"
built
check "a link where a package should be is refused" "1" "$rc"
fresh 6.2.0+r12
rm -r "$WORK/in/deb-amd64"
ln -s deb-arm64 "$WORK/in/deb-amd64"
built
check "a link where an artifact directory should be is refused" "1" "$rc"
fresh 6.2.0+r12
mkfifo "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb.fifo"
built
check "a fifo is refused" "1" "$rc"
fresh 6.2.0+r12
ln -s in "$WORK/inlink"
out="$(bash "$SCRIPT" built v6.2.0+r12 "$WORK/inlink" "$WORK/out" 2>&1)"; rc=$?
check "a download directory that is itself a link is refused" "1" "$rc"
rm -f "$WORK/inlink"
out="$(bash "$SCRIPT" built v6.2.0+r12 "$WORK/absent" "$WORK/out" 2>&1)"; rc=$?
check "a download directory that is not there is refused" "1" "$rc"

# --- the destination -------------------------------------------------------------------
fresh 6.2.0+r12
mkdir "$WORK/out"; echo x > "$WORK/out/old.py"
built
check "an output directory that is not empty is refused" "1 1" "$rc $(says 'is not an empty directory')"
fresh 6.2.0+r12
ln -s /tmp "$WORK/out"
built
check "an output directory that is a link is refused" "1" "$rc"
rm -f "$WORK/out"

# --- the size of a package -----------------------------------------------------------
fresh 6.2.0+r12
truncate -s 301M "$WORK/in/deb-amd64/podman_6.2.0+r12_amd64.deb"
built
check "a package over the cap is refused, before its control file is read" "1" "$rc"

# --- the signed set --------------------------------------------------------------------
signed_dir() { # <mldsa true|false>
	rm -rf "$WORK/sg"; mkdir "$WORK/sg"
	local a
	for a in amd64 arm64; do
		mkdeb "$WORK/sg/podman_6.2.0+r12_$a.deb" podman 6.2.0+r12 "$a"
		head -c 64 /dev/zero > "$WORK/sg/podman_6.2.0+r12_$a.deb.sig"
		[ "$1" != true ] || head -c 3309 /dev/zero > "$WORK/sg/podman_6.2.0+r12_$a.deb.mldsa65.sig"
	done
	fake_rpms "$WORK/sg" 6.2.0+r12
	printf 'release v6.2.0+r12\n' > "$WORK/sg/components.txt"
	printf 'sums\n' > "$WORK/sg/SHA256SUMS"
	local name
	while IFS= read -r name; do
		head -c 64 /dev/zero > "$WORK/sg/$name.sig"
		[ "$1" != true ] || head -c 3309 /dev/zero > "$WORK/sg/$name.mldsa65.sig"
	done <<< "$( { rpm_names 6.2.0+r12; printf 'components.txt\nSHA256SUMS\n'; } )"
}
signed() { out="$(bash "$SCRIPT" signed v6.2.0+r12 "$WORK/sg" "$1" 2>&1)"; rc=$?; }
signed_dir false; signed false
check "the signed set with the first signature only passes when the second is not required" "0" "$rc"
signed_dir true; signed true
check "the signed set with both signatures passes when the second is required" "0" "$rc"
signed_dir false; signed true
check "a required second signature that is missing is refused" "1 1" "$rc $(says 'not exactly the expected one')"
signed_dir true; signed false
check "a second signature nobody required is refused too" "1" "$rc"
signed_dir true; rm "$WORK/sg/podman_6.2.0+r12_arm64.deb.sig"; signed true
check "a missing first signature is refused" "1" "$rc"
signed_dir true; echo x > "$WORK/sg/venv.py"; signed true
check "a file of more in the signed set is refused" "1" "$rc"
signed_dir true; head -c 63 /dev/zero > "$WORK/sg/podman_6.2.0+r12_amd64.deb.sig"; signed true
check "an Ed25519 signature of the wrong size is refused" "1 1" "$rc $(says 'is not 64 bytes')"
signed_dir true; head -c 3308 /dev/zero > "$WORK/sg/podman_6.2.0+r12_amd64.deb.mldsa65.sig"; signed true
check "an ML-DSA-65 signature of the wrong size is refused" "1 1" "$rc $(says 'is not 3309 bytes')"
signed_dir false; rm "$WORK/sg/podman_6.2.0+r12_amd64.deb.sig"; ln -s podman_6.2.0+r12_arm64.deb.sig "$WORK/sg/podman_6.2.0+r12_amd64.deb.sig"; signed false
check "a link in place of a signature is refused" "1" "$rc"
signed_dir false; truncate -s 301M "$WORK/sg/podman_6.2.0+r12_amd64.deb"; signed false
check "a signed package over the cap is refused" "1 1" "$rc $(says 'over the size cap')"
signed_dir false
out="$(bash "$SCRIPT" signed v6.2.0+r12 "$WORK/sg" maybe 2>&1)"; rc=$?
check "a second-signature flag that is neither true nor false is refused" "1 1" "$rc $(says 'is true or false')"
out="$(bash "$SCRIPT" signed v6.2.0+r11 "$WORK/sg" false 2>&1)"; rc=$?
check "a signed set of another version is refused" "1" "$rc"
for gone in "$one" "$one.sig" SHA256SUMS SHA256SUMS.sig; do
	signed_dir false; rm "$WORK/sg/$gone"; signed false
	check "a signed set without $gone is refused" "1 1" "$rc $(says 'not exactly the expected one')"
done
signed_dir true; rm "$WORK/sg/$one.mldsa65.sig"; signed true
check "a required second signature missing from one rpm package is refused" "1 1" "$rc $(says 'not exactly the expected one')"
signed_dir true; rm "$WORK/sg/SHA256SUMS.mldsa65.sig"; signed true
check "and from the list of hashes" 1 "$rc"
signed_dir false; head -c 63 /dev/zero > "$WORK/sg/$one.sig"; signed false
check "a signature of an rpm package of the wrong size is refused" "1 1" "$rc $(says 'is not 64 bytes')"
signed_dir false; truncate -s 301M "$WORK/sg/$one"; signed false
check "a signed rpm package over the cap is refused" "1 1" "$rc $(says 'over the size cap')"
signed_dir false; head -c 65537 /dev/zero > "$WORK/sg/SHA256SUMS"; signed false
check "a SHA256SUMS over the cap is refused" "1 1" "$rc $(says 'SHA256SUMS is over the size cap')"
signed_dir false
out="$(GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" signed v6.2.0+r12 "$WORK/sg" false 2>&1)"; rc=$?
check "a signed set whose files cannot be named is refused" "1 1" "$rc $(says 'the files of v6.2.0+r12 cannot be named')"
signed_dir false; rm "$WORK/sg/components.txt"; signed false
check "a signed set without components.txt is refused" "1 1" "$rc $(says 'not exactly the expected one')"
signed_dir false; rm "$WORK/sg/components.txt.sig"; signed false
check "and one without the signature of components.txt" "1 1" "$rc $(says 'not exactly the expected one')"
signed_dir true; rm "$WORK/sg/components.txt.mldsa65.sig"; signed true
check "and one without its second signature when that is required" "1 1" "$rc $(says 'not exactly the expected one')"
signed_dir false; head -c 63 /dev/zero > "$WORK/sg/components.txt.sig"; signed false
check "a signature of components.txt of the wrong size is refused" "1 1" "$rc $(says 'is not 64 bytes')"
signed_dir false; head -c 4097 /dev/zero > "$WORK/sg/components.txt"; signed false
check "a components.txt over the cap is refused" "1 1" "$rc $(says 'components.txt is over the size cap')"
signed_dir false; rm "$WORK/sg/components.txt"; ln -s podman_6.2.0+r12_amd64.deb.sig "$WORK/sg/components.txt"; signed false
check "a link in place of components.txt is refused" "1" "$rc"

# --- usage -------------------------------------------------------------------------------
bash "$SCRIPT" > /dev/null 2>&1; check "no arguments is a usage error" 2 "$?"
bash "$SCRIPT" verify v6.2.0 "$WORK/sg" > /dev/null 2>&1; check "an unknown mode is a usage error" 2 "$?"
bash "$SCRIPT" built v6.2.0 "$WORK/sg" > /dev/null 2>&1; check "built without a destination is a usage error" 2 "$?"
bash "$SCRIPT" signed v6.2.0 "$WORK/sg" > /dev/null 2>&1; check "signed without the second-signature flag is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
