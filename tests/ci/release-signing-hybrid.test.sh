#!/usr/bin/env bash
#
# The hybrid release signature in .github/scripts/release/{sign,verify-sig}.py,
# the half that needs no ML-DSA library: which second signature is required,
# which one is refused before any cryptography runs, the refusal when the
# library cannot check one, and sign.py with no second key or a bad one. The
# cases that make and verify a real ML-DSA-65 signature are in
# tests/ci/release-signing-mldsa.test.sh, which needs cryptography 50.0.2.
#
# Every case asserts the reason of a refusal, not only the exit status, and the
# ML-DSA-65 inputs are valid in every respect except the one under test: a
# public key is 1952 bytes of valid base64 and a signature is 3309 bytes, so the
# check that refuses is the one the case names.
#
# Requires: python3 with the `cryptography` module (any version with Ed25519).
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN="$HERE/.github/scripts/release/sign.py"
VERIFY="$HERE/.github/scripts/release/verify-sig.py"
COMMITTED="$HERE/keyring/glyndor-release-mldsa65.b64"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# expect <want-exit> <needle> <desc> -- <command...>
# The needle must appear in the combined output; an empty needle accepts any.
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

# refute <needle> <desc> -- <command...>: the output must NOT carry the needle.
refute() {
	local needle="$1" desc="$2"
	shift 3
	local out
	out="$("$@" 2>&1)" || true
	if printf '%s' "$out" | grep -qF -- "$needle"; then
		fail=$((fail + 1)); echo "FAIL  $desc (found '$needle': $out)"
	else
		pass=$((pass + 1)); echo "ok    $desc"
	fi
}

# absent <desc> <path...>: none of the paths may exist.
absent() {
	local desc="$1" p
	shift
	for p in "$@"; do
		if [ -e "$p" ]; then fail=$((fail + 1)); echo "FAIL  $desc ($p exists)"; return; fi
	done
	pass=$((pass + 1)); echo "ok    $desc"
}

# An Ed25519 key, a stand-in ML-DSA-65 public key (1952 random bytes are a
# well-formed key file entry, which is all the checks here read), one 31 bytes
# short of a key, and seeds of the right and wrong length.
python3 - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
w = sys.argv[1]
def put(name, text):
	open(os.path.join(w, name), "w").write(text)
b64 = lambda raw: base64.b64encode(raw).decode()
k = Ed25519PrivateKey.generate()
put("seed", b64(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())))
put("ed.b64", b64(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)) + "\n")
put("pq.b64", "# a key\n" + b64(os.urandom(1952)) + "\n")
put("pq-short.b64", b64(os.urandom(1951)) + "\n")
put("ed-short.b64", b64(os.urandom(31)) + "\n")
put("pq-seed", b64(os.urandom(32)))
put("pq-seed-31", b64(os.urandom(31)))
put("pq-seed-33", b64(os.urandom(33)))
PY
printf '# no key yet\n\n' > "$WORK/pq-none.b64"
key="$(grep -v '^#' "$WORK/pq.b64")"
printf '%s!%s\n' "${key:0:40}" "${key:40}" > "$WORK/pq-stray.b64"
ED_SEED="$(cat "$WORK/seed")"

# make_case <dir> -> <dir>/file with a valid Ed25519 signature; prints its path.
make_case() {
	mkdir -p "$1"
	echo "payload $1" > "$1/file"
	GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" python3 "$SIGN" "$1/file" > /dev/null
	echo "$1/file"
}

# --- row 2: no second signature, not required: accepted, as before ------------
f="$(make_case "$WORK/row2")"
expect 0 "verified $f" "the three-argument call verifies the Ed25519 signature alone, as before" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64"
expect 0 "no ML-DSA-65 signature, and none is required" "no second signature and none required is accepted" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"
expect 0 "verified $f" "and so it is with no ML-DSA-65 key file at all" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/absent.b64"
expect 0 "verified $f" "and with the committed ML-DSA-65 key file, which release.yml passes" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$COMMITTED"

# --- row 3: no second signature, required: refused for that -------------------
expect 1 "the hybrid release signature is required" "a required second signature that is missing is refused" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64" \
	--require-mldsa
expect 1 "the hybrid release signature is required" "and so it is with no ML-DSA-65 key configured" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --require-mldsa

# --- row 5: a second signature and no ML-DSA-65 key configured ------------------
f="$(make_case "$WORK/row5")"; head -c 3309 /dev/urandom > "$f.mldsa65.sig"
expect 1 "no ML-DSA-65 release public key is configured" "a second signature with no key configured is refused" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq-none.b64"
expect 1 "no ML-DSA-65 release public key is configured" "and so it is with no key file" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/absent.b64"
expect 1 "no ML-DSA-65 release public key is configured" "and with no --mldsa-keys at all" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig"
ln -s "$WORK/nowhere" "$WORK/row5/dangling"
expect 1 "cannot read the ML-DSA-65 signature file" "a dangling link is a second signature that is there and unreadable" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$WORK/row5/dangling" --mldsa-keys "$WORK/pq.b64"

# --- row 6: the Ed25519 signature decides first --------------------------------
f="$(make_case "$WORK/row6")"; head -c 3309 /dev/urandom > "$f.mldsa65.sig"
head -c 64 /dev/zero > "$f.sig"
expect 1 "no release key verifies $f" "an invalid Ed25519 signature is refused beside a second one" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64" \
	--require-mldsa
refute "ML-DSA-65" "and the refusal is the Ed25519 one, checked before the second" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"
rm "$f.sig"
expect 1 "no Ed25519 signature for $f" "a missing Ed25519 signature is refused beside a second one" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"

# --- the second signature's length, before any cryptography --------------------
f="$(make_case "$WORK/length")"
for n in 3308 3310 0; do
	head -c "$n" /dev/urandom > "$f.mldsa65.sig"
	expect 1 "ML-DSA-65 signature is $n bytes, expected exactly 3309" "a $n-byte second signature is refused for its length" \
		-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"
done
head -c 5000 /dev/urandom > "$f.mldsa65.sig"
expect 1 "is over 4096 bytes" "a second signature over the read cap is refused by the bounded read" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"
rm "$f.mldsa65.sig"; mkdir "$f.mldsa65.sig"
expect 1 "cannot read the ML-DSA-65 signature file" "a second signature that cannot be read is refused as unreadable" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"

# --- our own key files: exit 2, never reported as a bad signature ---------------
f="$(make_case "$WORK/anchor")"
expect 2 "malformed ML-DSA-65 public key on line 1" "an ML-DSA-65 key with a character outside base64 is our malformed file" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq-stray.b64"
expect 2 "1951 bytes, expected 1952" "a 1951-byte ML-DSA-65 key is refused for its length" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq-short.b64"
refute "verifies" "and neither reads as a signature that failed" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq-short.b64"
key="$(cat "$WORK/ed.b64")"
printf '%s!%s\n' "${key:0:10}" "${key:10}" > "$WORK/ed-stray.b64"
expect 2 "malformed Ed25519 public key on line 1" "an Ed25519 key with a stray character is our malformed file" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed-stray.b64"
printf '\357\273\277%s\n' "$key" > "$WORK/ed-bom.b64"
expect 2 "malformed Ed25519 public key on line 1" "an Ed25519 key behind a byte-order mark is our malformed file, not a crash" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed-bom.b64"
expect 2 "31 bytes, expected 32" "an Ed25519 key of the wrong length is refused for its length" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed-short.b64"
expect 2 "not found" "a missing Ed25519 key file is our error" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/absent.b64"
expect 2 "no public keys to verify against" "an Ed25519 key file with only comments has no key" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/pq-none.b64"
{ echo "# the release key"; cat "$WORK/ed.b64"; } > "$WORK/ed-commented.b64"
expect 0 "verified $f" "comment lines in a key file are skipped" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed-commented.b64"

# --- options that only mean something with --mldsa-sig --------------------------
expect 2 "need --mldsa-sig" "--require-mldsa without --mldsa-sig is a usage error, not a silent pass" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --require-mldsa
expect 2 "need --mldsa-sig" "and so is --mldsa-keys without it" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-keys "$WORK/pq.b64"

# --- the library cannot check ML-DSA: refused and said ---------------------------
# The runner's python3-cryptography has no ML-DSA. The blocker makes that true
# on any machine, so the case does not depend on which version is installed.
mkdir -p "$WORK/no-mldsa"
cat > "$WORK/no-mldsa/sitecustomize.py" <<'PY'
import sys
class Block:
	def find_spec(self, name, path=None, target=None):
		if name == "cryptography.hazmat.primitives.asymmetric.mldsa":
			raise ModuleNotFoundError("No module named " + repr(name))
sys.meta_path.insert(0, Block())
PY
f="$(make_case "$WORK/nolib")"; head -c 3309 /dev/urandom > "$f.mldsa65.sig"
expect 1 "the installed cryptography has no ML-DSA support" "a second signature the library cannot check is refused" \
	-- env PYTHONPATH="$WORK/no-mldsa" python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" \
	--mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"
rm "$f.mldsa65.sig"
expect 0 "verified $f" "and without a second signature the same machine accepts the file" \
	-- env PYTHONPATH="$WORK/no-mldsa" python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" \
	--mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$WORK/pq.b64"

# --- sign.py without a second key: Ed25519 only, and it says so -------------------
d="$WORK/sign"; mkdir -p "$d"; echo payload > "$d/file"
expect 0 "GLYNDOR_RELEASE_MLDSA65_KEY is not set; wrote the Ed25519 signature only" \
	"signing with no ML-DSA-65 key writes the Ed25519 signature only and says so" \
	-- env -u GLYNDOR_RELEASE_MLDSA65_KEY GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" python3 "$SIGN" "$d/file"
if [ -s "$d/file.sig" ]; then pass=$((pass + 1)); echo "ok    and the Ed25519 signature is written"
else fail=$((fail + 1)); echo "FAIL  and the Ed25519 signature is written"; fi
absent "and no second signature" "$d/file.mldsa65.sig"
rm -f "$d/file.sig"
expect 0 "wrote the Ed25519 signature only" "an empty key, which is how a secret that is not configured arrives, is unset" \
	-- env GLYNDOR_RELEASE_MLDSA65_KEY= GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" python3 "$SIGN" "$d/file"
absent "and writes no second signature either" "$d/file.mldsa65.sig"

# --- sign.py with a bad second key: an error, and nothing written -----------------
rm -f "$d/file.sig"
bad_seed() { # <needle> <desc> <seed>
	expect 1 "$1" "$2" \
		-- env GLYNDOR_RELEASE_MLDSA65_KEY="$3" GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" python3 "$SIGN" "$d/file"
	absent "and writes neither signature" "$d/file.sig" "$d/file.mldsa65.sig"
}
bad_seed "GLYNDOR_RELEASE_MLDSA65_KEY is not valid base64" "a seed with a stray character is refused" \
	"$(cat "$WORK/pq-seed")!"
bad_seed "must decode to 32 bytes, got 31" "a 31-byte seed is refused" "$(cat "$WORK/pq-seed-31")"
bad_seed "must decode to 32 bytes, got 33" "a 33-byte seed is refused" "$(cat "$WORK/pq-seed-33")"
bad_seed "must decode to 32 bytes, got 0" "a seed of only spaces is set and is not a key" "   "
expect 1 "cannot sign ML-DSA-65" "a valid seed with a library that has no ML-DSA is refused, not signed with Ed25519 alone" \
	-- env PYTHONPATH="$WORK/no-mldsa" GLYNDOR_RELEASE_MLDSA65_KEY="$(cat "$WORK/pq-seed")" \
	GLYNDOR_RELEASE_ED25519_KEY="$ED_SEED" python3 "$SIGN" "$d/file"
absent "and writes neither signature" "$d/file.sig" "$d/file.mldsa65.sig"

# --- the committed key file ----------------------------------------------------
# release.yml passes it on every release. It must load: a broken file stops
# every release, with or without a second signature.
if [ -f "$COMMITTED" ]; then
	pass=$((pass + 1)); echo "ok    keyring/glyndor-release-mldsa65.b64 is committed"
else
	fail=$((fail + 1)); echo "FAIL  keyring/glyndor-release-mldsa65.b64 is committed"
fi
f="$(make_case "$WORK/committed")"
refute "malformed" "and it is a well-formed key file" \
	-- python3 "$VERIFY" "$f" "$f.sig" "$WORK/ed.b64" --mldsa-sig "$f.mldsa65.sig" --mldsa-keys "$COMMITTED"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
