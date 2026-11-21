#!/usr/bin/env bash
#
# Tests for .github/scripts/release/{sign,verify-sig}.py with a throwaway key:
# a signature made by the key verifies, a changed file or another key does not,
# and signing without a key fails instead of producing nothing.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN="$HERE/.github/scripts/release/sign.py"
VERIFY="$HERE/.github/scripts/release/verify-sig.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want-exit> <got-exit>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want exit $2, got $3)"; fi
}

genkey() { # <seed-file> <pub-file>
	python3 - "$1" "$2" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = Ed25519PrivateKey.generate()
seed = k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())
pub = k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
open(sys.argv[1], "w").write(base64.b64encode(seed).decode())
open(sys.argv[2], "w").write(base64.b64encode(pub).decode() + "\n")
PY
}

genkey "$WORK/seed" "$WORK/pub"
genkey "$WORK/seed2" "$WORK/pub2"
echo payload > "$WORK/file"

GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/seed")" python3 "$SIGN" "$WORK/file" >/dev/null 2>&1
check "signing writes a signature" 0 "$?"
python3 "$VERIFY" "$WORK/file" "$WORK/file.sig" "$WORK/pub" >/dev/null 2>&1; check "own key verifies" 0 "$?"
python3 "$VERIFY" "$WORK/file" "$WORK/file.sig" "$WORK/pub2" >/dev/null 2>&1; check "another key does not verify" 1 "$?"
cat "$WORK/pub2" "$WORK/pub" > "$WORK/both"
python3 "$VERIFY" "$WORK/file" "$WORK/file.sig" "$WORK/both" >/dev/null 2>&1; check "any listed key may verify" 0 "$?"
echo changed > "$WORK/file"
python3 "$VERIFY" "$WORK/file" "$WORK/file.sig" "$WORK/pub" >/dev/null 2>&1; check "a changed file does not verify" 1 "$?"
env -u GLYNDOR_RELEASE_ED25519_KEY python3 "$SIGN" "$WORK/file" "$WORK/x.sig" >/dev/null 2>&1; check "signing without a key fails" 1 "$?"
[ ! -e "$WORK/x.sig" ]; check "and writes no signature" 0 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
