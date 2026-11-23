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
err="$(env -u GLYNDOR_RELEASE_ED25519_KEY python3 "$SIGN" "$WORK/file" "$WORK/x.sig" 2>&1 >/dev/null)"; check "signing without a key fails" 1 "$?"
check "and writes no signature" 0 "$([ -e "$WORK/x.sig" ] && echo 1 || echo 0)"
printf '%s\n' "$err" | grep -q -x 'GLYNDOR_RELEASE_ED25519_KEY is not set; refusing to publish an unsigned artifact'
check "and says the key is not set, not that it is malformed" 0 "$?"
err="$(GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/seed")" python3 "$SIGN" 2>&1 >/dev/null)"; check "signing with no file to sign fails" 1 "$?"
printf '%s\n' "$err" | grep -q -x '  sign.py <input-file> \[<output-sig-file>\]'
check "and prints its usage, not a traceback" "0 0" "$? $(printf '%s\n' "$err" | grep -c Traceback)"

# What the verifier cannot read is a refusal, and says which file.
echo payload > "$WORK/file"
GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/seed")" python3 "$SIGN" "$WORK/file" >/dev/null 2>&1
err="$(python3 "$VERIFY" "$WORK/file" "$WORK/absent.sig" "$WORK/pub" 2>&1)"; check "a signature that is not there is refused" 1 "$?"
printf '%s\n' "$err" | grep -q "^no Ed25519 signature for $WORK/file: "; check "and it says the signature is missing" 0 "$?"
err="$(python3 "$VERIFY" "$WORK/absent" "$WORK/file.sig" "$WORK/pub" 2>&1)"; check "a file that is not there is refused" 1 "$?"
printf '%s\n' "$err" | grep -q "^cannot read $WORK/absent: "; check "and it says which file it could not read" 0 "$?"

# A link is not what was built. Signing or verifying the file a link points at would sign what
# somebody put in a package's place, and a signature written through a link lands somewhere else.
echo payload > "$WORK/real"
ln -s real "$WORK/link"
err="$(GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/seed")" python3 "$SIGN" "$WORK/link" 2>&1 >/dev/null)"; check "signing a link is refused" 1 "$?"
printf '%s\n' "$err" | grep -q "^refusing to sign $WORK/link: "; check "and it says it will not sign it" 0 "$?"
check "and no signature was written" 0 "$([ -e "$WORK/link.sig" ] && echo 1 || echo 0)"
mkdir "$WORK/dir"
GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/seed")" python3 "$SIGN" "$WORK/dir" >/dev/null 2>&1; check "signing a directory is refused" 1 "$?"
echo elsewhere > "$WORK/target"
ln -s target "$WORK/out.sig"
err="$(GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/seed")" python3 "$SIGN" "$WORK/real" "$WORK/out.sig" 2>&1 >/dev/null)"; check "a signature is not written through a link" 1 "$?"
printf '%s\n' "$err" | grep -q "^cannot write $WORK/out.sig: "; check "and it says which path" 0 "$?"
check "and what the link pointed at is untouched" "elsewhere" "$(cat "$WORK/target")"
GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/seed")" python3 "$SIGN" "$WORK/real" >/dev/null 2>&1
err="$(python3 "$VERIFY" "$WORK/link" "$WORK/real.sig" "$WORK/pub" 2>&1)"; check "verifying a link is refused" 1 "$?"
printf '%s\n' "$err" | grep -q "^cannot read $WORK/link: "; check "and it says it cannot read it" 0 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
