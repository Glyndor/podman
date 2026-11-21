#!/usr/bin/env bash
#
# The bytes a key file may hold, as .github/scripts/release/verify-sig.py reads it.
# The release workflow, the steps of docs/verify.md and the apt archive split a key
# file on the line feed alone; splitlines() in the verifier also splits on a carriage
# return, a form feed, a U+0085 and more. A key behind one of those was a key to the
# verifier and part of a comment to every other reader, so a package signed with it
# verified here and nowhere else. The verifier now refuses such a file as a broken
# trust anchor (exit 2), for the Ed25519 keys and the ML-DSA-65 keys alike.
#
# Each refused file holds a key that verifies the signature, so the refusal is for the
# byte and not for the key; the same key on a line of its own is accepted.
#
# Requires: python3 with the `cryptography` module (any version with Ed25519).
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$HERE/.github/scripts/release/verify-sig.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# expect <want-exit> <needle> <desc> -- <command...>: the needle must be in the output.
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

f="$WORK/podman_6.2.0_amd64.deb"
python3 -I - "$f" "$WORK/key.b64" <<'PY' || { echo "FAIL  cannot make an Ed25519 test key"; exit 1; }
import base64, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
path, keyfile = sys.argv[1:3]
key = Ed25519PrivateKey.generate()
data = b"a package\n"
open(path, "wb").write(data)
open(path + ".sig", "wb").write(key.sign(data))
raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
open(keyfile, "w").write(base64.b64encode(raw).decode().rstrip("=") + "\n")
PY
key="$(cat "$WORK/key.b64")"
bytes='holds a byte that is neither printable ASCII nor a line feed'

# --- the shapes every reader agrees on ------------------------------------------
printf '# the release key\n\n%s\n' "$key" > "$WORK/ok.b64"
expect 0 "verified $f" "a comment, a blank line and the key on a line of its own: verified" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ok.b64"
printf '# the release key\n%s' "$key" > "$WORK/no-final-lf.b64"
expect 0 "verified $f" "and the key with no line feed after it" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/no-final-lf.b64"
# The anchor this repository commits passes the byte check and parses: the package is
# refused because that key did not sign it, which is exit 1 and not a broken anchor.
expect 1 "no release key verifies $f" "the Ed25519 anchor this repository commits is read, and its key is not the test's" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$HERE/keyring/glyndor-release-ed25519.b64"

# A key file that exists and cannot be read is the anchor broken, not a missing one.
mkdir "$WORK/a-directory.b64"
expect 2 "cannot read the Ed25519 key file $WORK/a-directory.b64" "a key file that cannot be read is a broken anchor, and says so" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/a-directory.b64"

# --- the shapes where the readers disagree --------------------------------------
# <name>:<contents for printf %b>. Each holds the key that verifies the package.
cases=(
	"cr:# the release key\r$key\n"
	"crlf:$key\r\n"
	"bom:\357\273\277$key\n"
	"tab:\t$key\n"
	"nul:# a comment\0000$key\n"
	"high:# \200\n$key\n"
	"nel:# the release key\302\205$key\n"
	"line-separator:# the release key\342\200\250$key\n"
	"form-feed:# the release key\f$key\n"
	"vertical-tab:# the release key\v$key\n"
)
for c in "${cases[@]}"; do
	name="${c%%:*}"
	printf '%b' "${c#*:}" > "$WORK/$name.b64"
	expect 2 "Ed25519 key file $WORK/$name.b64 $bytes" "an Ed25519 key file with a $name: a broken anchor, not a verified package" \
		-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/$name.b64"
done

# The ML-DSA-65 key file is read the same way. It is read before the second signature
# is looked at, so a signature of the right length is enough to reach it.
head -c 3309 /dev/zero > "$f.mldsa65.sig"
for name in cr nel; do
	case "$name" in
		cr) printf '# the ML-DSA-65 keys\rAAAA\n' > "$WORK/pq-$name.b64" ;;
		nel) printf '# the ML-DSA-65 keys\302\205AAAA\n' > "$WORK/pq-$name.b64" ;;
	esac
	expect 2 "ML-DSA-65 key file $WORK/pq-$name.b64 $bytes" "an ML-DSA-65 key file with a $name: a broken anchor" \
		-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ok.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq-$name.b64"
done
expect 0 "no ML-DSA-65 signature" "a missing ML-DSA-65 key file is still no key configured, not a broken one" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ok.b64" --mldsa-sig "$WORK/absent.sig" --mldsa-keys "$WORK/absent.b64"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
