#!/usr/bin/env bash
#
# Tests for scripts/release/signed-set.sh: the record of a release, its list of hashes, the list of what is signed and
# attached, and the check of everything a release signs. The packages and the record are signed with the real sign.py
# under keys made for the run, and verified with the real verify-sig.py through an environment that is the system's
# interpreter.
# Requires: python3 with the cryptography library (Ed25519).
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/release/signed-set.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
says() { printf '%s\n' "$out" | grep -c -- "$1"; }

# shellcheck source=tests/lib/rpm-set.sh
. "$HERE/tests/lib/rpm-set.sh"

mkdir -p "$WORK/venv/bin"
ln -s "$(command -v python3)" "$WORK/venv/bin/python"
python3 -I "$HERE/.github/scripts/release/dry-run-keys.py" "$WORK/keys" > /dev/null
python3 -I "$HERE/.github/scripts/release/dry-run-keys.py" "$WORK/other" > /dev/null
printf '# none\n' > "$WORK/mldsa.b64"
export TAG=v6.2.0+r3 PODMAN=v6.2.0 NETAVARK=v2.1.0 AARDVARK=v2.1.3 RECIPE=f62986483d32
set_dir="$WORK/set"

# --- the record ---------------------------------------------------------------------------------
mkdir "$set_dir"
out="$(bash "$SCRIPT" components "$set_dir/components.txt" 2>&1)"; rc=$?
check "the record is written" 0 "$rc"
ids="$(bash "$HERE/scripts/package/distros.sh" ids rpm | paste -sd' ')"
recipe="$(bash "$HERE/scripts/build/recipe-id.sh" "$HERE/scripts/package")"
check "with the release first, the four components the plan compares, the distributions and the recipe of their packages" \
	"release v6.2.0+r3|podman v6.2.0|netavark v2.1.0|aardvark-dns v2.1.3|recipe f62986483d32|ids $ids|recipe-package $recipe" "$(paste -sd'|' "$set_dir/components.txt")"
check "and the recipe of the packages is a digest" 1 "$(grep -c -x -E 'recipe-package [0-9a-f]{12}' "$set_dir/components.txt")"
out="$(GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" components "$WORK/rec" 2>&1)"; rc=$?
check "a table that cannot be read writes no record, and says so" "1 absent 1" \
	"$rc $([ -e "$WORK/rec" ] && echo present || echo absent) $(says 'the rpm rows of distros.txt cannot be read')"
# A copy of the scripts whose recipe cannot be read: no record without it.
mkdir -p "$WORK/copy/scripts"
cp -r "$HERE/scripts/release" "$WORK/copy/scripts/release"
cp -r "$HERE/scripts/package" "$WORK/copy/scripts/package"
mkdir "$WORK/copy/scripts/build"; printf 'exit 1\n' > "$WORK/copy/scripts/build/recipe-id.sh"
out="$(bash "$WORK/copy/scripts/release/signed-set.sh" components "$WORK/rec" 2>&1)"; rc=$?
check "a recipe of the packages that cannot be read writes no record" "1 absent 1" \
	"$rc $([ -e "$WORK/rec" ] && echo present || echo absent) $(says 'the recipe of scripts/package cannot be read')"
printf 'arch|pacman|arch|x86_64|0|0|0|upstream|20260716||\n' > "$WORK/empty.txt"
out="$(GLYNDOR_DISTROS_FILE="$WORK/empty.txt" bash "$SCRIPT" components "$WORK/rec" 2>&1)"; rc=$?
check "a table with no rpm row writes no record" "1 absent 1" "$rc $([ -e "$WORK/rec" ] && echo present || echo absent) $(says 'no rpm row')"

# --- what is signed and what is attached, for the committed table ---------------------------------
listed="$(bash "$SCRIPT" list)"
want="$( { printf 'podman_6.2.0+r3_amd64.deb\npodman_6.2.0+r3_arm64.deb\n'; rpm_names 6.2.0+r3; printf 'components.txt\nSHA256SUMS\n'; } )"
check "what is signed is the two .deb, every rpm package, the record and the hashes" "$want" "$listed"
check "which are forty four files" 44 "$(grep -c . <<< "$listed")"
plain="$(bash "$SCRIPT" assets false)"
check "a release attaches each of them with its signature" 88 "$(grep -c . <<< "$plain")"
check "and no second signature that was not required" 0 "$(grep -c mldsa65 <<< "$plain")"
both="$(bash "$SCRIPT" assets true)"
check "a required second signature adds one for each" "132 44" "$(grep -c . <<< "$both") $(grep -c 'mldsa65' <<< "$both")"
check "and the assets of a file are the file, its signature and the second one, in that order" \
	"SHA256SUMS|SHA256SUMS.sig|SHA256SUMS.mldsa65.sig" "$(tail -n 3 <<< "$both" | paste -sd'|')"
for bad in "" maybe; do
	out="$(bash "$SCRIPT" assets "$bad" 2>&1)"; rc=$?
	check "a flag of '$bad' names no assets" "1 1" "$rc $(says 'is true or false')"
done
for mode in list "assets false"; do
	# shellcheck disable=SC2086 # the mode and its flag are two words
	out="$(GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" $mode 2>&1)"; rc=$?
	check "$mode names nothing when the packages cannot be named" "1 0" "$rc $(grep -c '^podman_' <<< "$out")"
done
for name in PODMAN NETAVARK AARDVARK RECIPE; do
	for value in "" "v1 v2" 'a;b' $'v1\nrelease v9.9.9'; do
		rm -f "$WORK/rec"
		out="$(env "$name=$value" bash "$SCRIPT" components "$WORK/rec" 2>&1)"; rc=$?
		check "a $name of '$(printf '%s' "$value" | head -n 1)' writes nothing and says which" "1 absent 1" \
			"$rc $([ -e "$WORK/rec" ] && echo present || echo absent) $(says "^$name is")"
	done
done
for bad in "" main v6.2 'v6.2.0+r3 x'; do
	out="$(TAG="$bad" bash "$SCRIPT" components "$WORK/rec" 2>&1)"; rc=$?
	check "the tag '$bad' is refused" "1 1" "$rc $(says 'is not vX.Y.Z')"
done

# --- the check of the signed set ------------------------------------------------------------------
# From here on a table of three distributions: what is verified is the set, and every file of it is signed and verified.
small_table "$WORK/distros.txt"
sign_file() { # <file> [seed]: signs it as the release does
	( read -r GLYNDOR_RELEASE_ED25519_KEY < "${2:-$WORK/keys/ed25519.seed}"; export GLYNDOR_RELEASE_ED25519_KEY
		python3 -I "$HERE/.github/scripts/release/sign.py" "$1" > /dev/null )
}
# A whole set is signed once for each seed and copied after: forty four files take seconds to sign.
signed() { # <seed>: the whole set of the release, hashed and signed
	local master="$WORK/master-${1:+other}"
	rm -rf "$set_dir"
	if [ -d "$master" ]; then cp -a "$master" "$set_dir"; return; fi
	mkdir "$set_dir"
	bash "$SCRIPT" components "$set_dir/components.txt"
	printf 'a package\n' > "$set_dir/podman_6.2.0+r3_amd64.deb"; printf 'another\n' > "$set_dir/podman_6.2.0+r3_arm64.deb"
	fake_rpms "$set_dir" 6.2.0+r3
	bash "$SCRIPT" sums "$set_dir"
	local f
	while IFS= read -r f; do sign_file "$set_dir/$f" "${1:-}"; done <<< "$(bash "$SCRIPT" list)"
	cp -a "$set_dir" "$master"
}
verify() { out="$(bash "$SCRIPT" verify "$set_dir" "$WORK/keys/ed25519.b64" "$WORK/mldsa.b64" "${1:-false}" "${2:-$WORK/venv}" 2>&1)"; rc=$?; }
signed; verify
check "a set signed with the release key verifies" 0 "$rc"
signed "$WORK/other/ed25519.seed"; verify
check "a set signed with another key is refused" "1 1" "$rc $(says 'does not verify')"
check "and its hashes are the ones sha256sum checks, one for every file but itself" "0 17" \
	"$(cd "$set_dir" && sha256sum --strict -c SHA256SUMS > /dev/null 2>&1; echo "$?") $(grep -c . "$set_dir/SHA256SUMS")"
rpm=podman-6.2.0+r3-3.glyndor.el9.aarch64.rpm
for f in podman_6.2.0+r3_amd64.deb podman_6.2.0+r3_arm64.deb "$rpm" components.txt SHA256SUMS; do
	signed; printf 'x\n' >> "$set_dir/$f"; verify
	check "$f changed after it was signed is refused, by name" "1 1" "$rc $(says "the signature of $f does not verify")"
	signed; rm "$set_dir/$f.sig"; verify
	check "$f with no signature is refused" 1 "$rc"
done
signed; verify true
check "a second signature that is required and absent is refused" "1 1" "$rc $(says 'does not verify')"
# A list of hashes that is signed and still not the one of the files: a line short, a line of more, a hash of another file.
for change in '1d' '$a 0000000000000000000000000000000000000000000000000000000000000000  extra' '1s/^[0-9a-f]\{4\}/ffff/'; do
	signed; sed -i "$change" "$set_dir/SHA256SUMS"; sign_file "$set_dir/SHA256SUMS"; verify
	check "a signed SHA256SUMS changed by '${change%% *}' is refused" "1 1" "$rc $(says 'SHA256SUMS is not the hashes of the files of the release')"
done
signed; rm "$set_dir/$rpm"; verify
check "a signed set that lacks a package is refused" 1 "$rc"
out="$(bash "$SCRIPT" sums "$set_dir" 2>&1)"; rc=$?
check "and no list of hashes is written over it" "1 1" "$rc $(says 'is not written without every file')"
signed; rm "$set_dir/SHA256SUMS"; chmod 000 "$set_dir/$rpm"
out="$(bash "$SCRIPT" sums "$set_dir" 2>&1)"; rc=$?
if [ -r "$set_dir/$rpm" ]; then
	echo "ok    a package that cannot be read is not hashed (run as a user that reads it anyway: not tried)"; pass=$((pass + 1))
else
	check "a package that cannot be read is not hashed" "1 absent 1" "$rc $([ -e "$set_dir/SHA256SUMS" ] && echo present || echo absent) $(says 'cannot be hashed')"
fi
signed; rm "$set_dir/$rpm" "$set_dir/SHA256SUMS"; ln -s podman_6.2.0+r3_amd64.deb "$set_dir/$rpm"
out="$(bash "$SCRIPT" sums "$set_dir" 2>&1)"; rc=$?
check "a link where a package should be is not hashed" "1 absent" "$rc $([ -e "$set_dir/SHA256SUMS" ] && echo present || echo absent)"
for change in '/^ids /d' 's/^ids .*/ids fc45/' '/^ids /p'; do
	signed; sed -i "$change" "$set_dir/components.txt"; sign_file "$set_dir/components.txt"; bash "$SCRIPT" sums "$set_dir"; sign_file "$set_dir/SHA256SUMS"; verify
	check "a signed record whose distributions are changed by '$change' is refused" "1 1" "$rc $(says 'does not name the distributions of the release')"
done
signed; sed -i 's/^release .*/release v6.2.0+r2/' "$set_dir/components.txt"
( read -r GLYNDOR_RELEASE_ED25519_KEY < "$WORK/keys/ed25519.seed"; export GLYNDOR_RELEASE_ED25519_KEY
	python3 -I "$HERE/.github/scripts/release/sign.py" "$set_dir/components.txt" > /dev/null )
verify
check "a signed record of another release is refused" "1 1" "$rc $(says 'does not name the release v6.2.0+r3, once')"
signed; printf 'release v6.2.0+r3\n' >> "$set_dir/components.txt"
( read -r GLYNDOR_RELEASE_ED25519_KEY < "$WORK/keys/ed25519.seed"; export GLYNDOR_RELEASE_ED25519_KEY
	python3 -I "$HERE/.github/scripts/release/sign.py" "$set_dir/components.txt" > /dev/null )
verify
check "a signed record that names its release twice is refused" "1 1" "$rc $(says 'does not name the release')"
signed; verify maybe
check "a second-signature flag that is neither true nor false is refused" "1 1" "$rc $(says 'is true or false')"
signed; verify false "$WORK/no-venv"
check "an environment that is not there is refused" "1 1" "$rc $(says 'the environment with the signing library is missing')"
check "the interpreter is started isolated" 1 "$(grep -c '"\$py" -I ' "$SCRIPT")"

# --- usage ----------------------------------------------------------------------------------------
bash "$SCRIPT" > /dev/null 2>&1; check "no arguments is a usage error" 2 "$?"
bash "$SCRIPT" sign > /dev/null 2>&1; check "an unknown mode is a usage error" 2 "$?"
bash "$SCRIPT" components > /dev/null 2>&1; check "components without a file is a usage error" 2 "$?"
bash "$SCRIPT" sums > /dev/null 2>&1; check "sums without a directory is a usage error" 2 "$?"
bash "$SCRIPT" list extra > /dev/null 2>&1; check "list with an argument is a usage error" 2 "$?"
bash "$SCRIPT" assets > /dev/null 2>&1; check "assets without a flag is a usage error" 2 "$?"
bash "$SCRIPT" verify "$set_dir" > /dev/null 2>&1; check "verify with too few arguments is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
