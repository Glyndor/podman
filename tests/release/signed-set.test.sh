#!/usr/bin/env bash
#
# Tests for scripts/release/signed-set.sh: the record of a release and the check of everything a release signs. The
# packages and the record are signed with the real sign.py under keys made for the run, and verified with the real
# verify-sig.py through an environment that is the system's interpreter.
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
check "with the release first and the four components the plan compares" \
	"release v6.2.0+r3|podman v6.2.0|netavark v2.1.0|aardvark-dns v2.1.3|recipe f62986483d32" "$(paste -sd'|' "$set_dir/components.txt")"
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
signed() { # <seed>: both packages and the record, signed
	rm -rf "$set_dir"; mkdir "$set_dir"
	bash "$SCRIPT" components "$set_dir/components.txt"
	printf 'a package\n' > "$set_dir/podman_6.2.0+r3_amd64.deb"; printf 'another\n' > "$set_dir/podman_6.2.0+r3_arm64.deb"
	( read -r GLYNDOR_RELEASE_ED25519_KEY < "${1:-$WORK/keys/ed25519.seed}"; export GLYNDOR_RELEASE_ED25519_KEY
		for f in "$set_dir"/*.deb "$set_dir/components.txt"; do python3 -I "$HERE/.github/scripts/release/sign.py" "$f" > /dev/null; done )
}
verify() { out="$(bash "$SCRIPT" verify "$set_dir" "$WORK/keys/ed25519.b64" "$WORK/mldsa.b64" "${1:-false}" "${2:-$WORK/venv}" 2>&1)"; rc=$?; }
signed; verify
check "a set signed with the release key verifies" 0 "$rc"
signed "$WORK/other/ed25519.seed"; verify
check "a set signed with another key is refused" "1 1" "$rc $(says 'does not verify')"
for f in podman_6.2.0+r3_amd64.deb podman_6.2.0+r3_arm64.deb components.txt; do
	signed; printf 'x\n' >> "$set_dir/$f"; verify
	check "$f changed after it was signed is refused, by name" "1 1" "$rc $(says "the signature of $f does not verify")"
	signed; rm "$set_dir/$f.sig"; verify
	check "$f with no signature is refused" 1 "$rc"
done
signed; verify true
check "a second signature that is required and absent is refused" "1 1" "$rc $(says 'does not verify')"
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
bash "$SCRIPT" verify "$set_dir" > /dev/null 2>&1; check "verify with too few arguments is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
