#!/usr/bin/env bash
#
# The hybrid release signature in .github/scripts/release/{sign,verify-sig}.py,
# verified for real: an Ed25519 signature and an ML-DSA-65 one over the same
# bytes, both required to pass. The checks that need no ML-DSA library are in
# tests/ci/release-signing-hybrid.test.sh.
#
# The keys are made here, at run time, and one fixed vector is checked as well.
# tests/fixtures/release-signing/mldsa65/ holds a public key, a message and the
# message's ML-DSA-65 signature, made with OpenSSL 3.5.5
# (`openssl genpkey -algorithm ML-DSA-65`, `openssl pkeyutl -sign -rawin`) and
# not with the library under test; it is the vector Glyndor/apt checks its own
# verifier against. A verifier that agrees only with itself passes the
# generated cases and fails that one.
#
# This suite needs cryptography 50.0.2 or later, which the runner's
# python3-cryptography is not. tests.yml runs it with a virtual environment
# built from .github/scripts/release/sign-requirements.txt first on PATH.
# Without the library it fails and says so: a suite that could not run is not
# a pass.
#
# Requires: python3 with cryptography >= 50.0.2.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN="$HERE/.github/scripts/release/sign.py"
VERIFY="$HERE/.github/scripts/release/verify-sig.py"
VECTOR="$HERE/tests/fixtures/release-signing/mldsa65"

if ! python3 -I -c 'from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey' 2>/dev/null; then
	echo "FAIL  $(command -v python3) has no cryptography with ML-DSA; install .github/scripts/release/sign-requirements.txt into a virtual environment and put it first on PATH"
	echo "0 passed, 1 failed"
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# expect <want-exit> <needle> <desc> -- <command...>
expect() {
	local want="$1" needle="$2" desc="$3"
	shift 4
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then
		pass=$((pass + 1)); echo "ok    $desc"
	else
		fail=$((fail + 1)); echo "FAIL  $desc (want exit $want with '$needle', got $got: $out)"
	fi
}

# One Ed25519 key and two ML-DSA-65 keys, as base64 seeds, and the public key
# files: pq-a.b64 and pq-b.b64 hold one key each, pq-ab.b64 both.
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey
w = sys.argv[1]
raw = s.Encoding.Raw
b64 = lambda b: base64.b64encode(b).decode()
def put(name, text):
	open(os.path.join(w, name), "w").write(text)
ed = Ed25519PrivateKey.generate()
put("ed.seed", b64(ed.private_bytes(raw, s.PrivateFormat.Raw, s.NoEncryption())))
put("ed.b64", b64(ed.public_key().public_bytes(raw, s.PublicFormat.Raw)) + "\n")
pub = {}
for name in ("a", "b"):
	seed = os.urandom(32)
	put("pq-%s.seed" % name, b64(seed))
	pub[name] = b64(MLDSA65PrivateKey.from_seed_bytes(seed).public_key().public_bytes(raw, s.PublicFormat.Raw))
	put("pq-%s.b64" % name, pub[name] + "\n")
put("pq-ab.b64", "# rotation overlap\n" + pub["a"] + "\n" + pub["b"] + "\n")
PY
ED_SEED="$(cat "$WORK/ed.seed")"

# sign <file> [a|b]: <file>.sig, and <file>.mldsa65.sig made with key a or b,
# both by sign.py itself, the way release.yml makes them.
sign() {
	if [ $# -eq 1 ]; then
		env -u GLYNDOR_RELEASE_MLDSA65_KEY GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" python3 "$SIGN" "$1" > /dev/null
	else
		GLYNDOR_RELEASE_MLDSA65_KEY="$(cat "$WORK/pq-$2.seed")" GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" \
			python3 "$SIGN" "$1" > /dev/null
	fi
}

# verify <file> <mldsa-keys> [--require-mldsa]
verify() {
	python3 "$VERIFY" "$1" "$1.sig" "$WORK/ed.b64" --mldsa-sig "$1.mldsa65.sig" --mldsa-keys "$2" "${@:3}"
}

# --- sign.py with the second key: two signatures that verify --------------------
mkdir "$WORK/sign"; f="$WORK/sign/file"; echo payload > "$f"
expect 0 "ML-DSA-65" "signing with an ML-DSA-65 key writes both signatures and says so" \
	-- env GLYNDOR_RELEASE_MLDSA65_KEY="$(cat "$WORK/pq-a.seed")" GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" \
	python3 "$SIGN" "$f"
expect 0 "3309" "and the second signature is 3309 bytes" -- wc -c "$f.mldsa65.sig"
expect 0 "verified $f" "and the Ed25519 one still verifies on its own, as every verifier in the field reads it" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64"
GLYNDOR_RELEASE_MLDSA65_KEY="$(cat "$WORK/pq-a.seed")" GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" \
	python3 "$SIGN" "$f" "$WORK/sign/custom.sig" > /dev/null
expect 0 "Ed25519 and ML-DSA-65" "with a custom .sig path the second signature is <name>.mldsa65.sig beside it" \
	-- python3 "$VERIFY" "$f" "$WORK/sign/custom.sig" "$WORK/ed.b64" --mldsa-sig "$WORK/sign/custom.mldsa65.sig" \
	--mldsa-keys "$WORK/pq-a.b64"

# --- row 1: both signatures valid --------------------------------------------------
expect 0 "verified $f (Ed25519 and ML-DSA-65)" "both signatures valid, not required: accepted" \
	-- verify "$f" "$WORK/pq-a.b64"
expect 0 "verified $f (Ed25519 and ML-DSA-65)" "both signatures valid, required: accepted" \
	-- verify "$f" "$WORK/pq-a.b64" --require-mldsa

# --- row 4: the second signature present and bad -------------------------------------
expect 1 "no ML-DSA-65 release key verifies $f" "a second signature made by a key that is not configured is refused" \
	-- verify "$f" "$WORK/pq-b.b64"
mkdir "$WORK/garbage"; g="$WORK/garbage/file"; echo payload > "$g"; sign "$g"
head -c 3309 /dev/urandom > "$g.mldsa65.sig"
expect 1 "no ML-DSA-65 release key verifies $g" "a second signature of the right length that does not verify is refused" \
	-- verify "$g" "$WORK/pq-a.b64"

# A valid signature one byte short or long is refused for its length, before
# the cryptographic check, so the reason is the length and not a library error.
mkdir "$WORK/length"; l="$WORK/length/file"; echo payload > "$l"; sign "$l" a
head -c 3308 "$l.mldsa65.sig" > "$WORK/short"; mv "$WORK/short" "$l.mldsa65.sig"
expect 1 "expected exactly 3309" "a valid second signature cut to 3308 bytes is refused for its length" \
	-- verify "$l" "$WORK/pq-a.b64"
sign "$l" a; printf 'x' >> "$l.mldsa65.sig"
expect 1 "expected exactly 3309" "a valid second signature with one byte appended is refused for its length" \
	-- verify "$l" "$WORK/pq-a.b64"

# --- two keys configured: either one may have signed (rotation overlap) ---------------
mkdir "$WORK/rotation"; r="$WORK/rotation/file"; echo payload > "$r"; sign "$r" b
expect 0 "verified $r (Ed25519 and ML-DSA-65)" "a signature by the second of two configured keys is accepted" \
	-- verify "$r" "$WORK/pq-ab.b64" --require-mldsa
expect 1 "no ML-DSA-65 release key verifies" "and refused when only the first key is configured" \
	-- verify "$r" "$WORK/pq-a.b64" --require-mldsa

# --- a valid second signature of ANOTHER file --------------------------------------
# Both files are genuine and both signatures verify for their own bytes.
# Swapping the sidecars must fail: the signature binds the bytes, not a name.
mkdir "$WORK/swap"; s1="$WORK/swap/one"; s2="$WORK/swap/two"
echo one > "$s1"; echo two > "$s2"; sign "$s1" a; sign "$s2" a
cp "$s2.mldsa65.sig" "$s1.mldsa65.sig"
expect 1 "no ML-DSA-65 release key verifies $s1" "a valid second signature of another file is refused" \
	-- verify "$s1" "$WORK/pq-a.b64"

# --- required, valid second signature, invalid first one -------------------------------
mkdir "$WORK/edbad"; e="$WORK/edbad/file"; echo payload > "$e"; sign "$e" a
head -c 64 /dev/zero > "$e.sig"
expect 1 "no release key verifies $e" "a valid second signature does not rescue an invalid Ed25519 one" \
	-- verify "$e" "$WORK/pq-a.b64" --require-mldsa

# --- the fixed vector, made by another implementation ----------------------------------
mkdir "$WORK/vector"; v="$WORK/vector/message"
base64 -d "$VECTOR/message.b64" > "$v"
base64 -d "$VECTOR/message.mldsa65.sig.b64" > "$v.mldsa65.sig"
sign "$v"
expect 0 "verified $v (Ed25519 and ML-DSA-65)" "the OpenSSL-made ML-DSA-65 vector verifies" \
	-- verify "$v" "$VECTOR/vector.mldsa65.b64" --require-mldsa
python3 -I - "$v.mldsa65.sig" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
b[1000] ^= 0x01
open(p, "wb").write(bytes(b))
PY
expect 1 "no ML-DSA-65 release key verifies $v" "and with one bit of its signature changed it does not" \
	-- verify "$v" "$VECTOR/vector.mldsa65.b64"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
