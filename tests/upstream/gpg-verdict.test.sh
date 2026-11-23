#!/usr/bin/env bash
#
# Tests for scripts/upstream/gpg-verdict.sh, the verdict both gates that trust a signature share. The statuses are
# the real ones: keys are made here, in a keyring of their own, and a file is signed and verified with gpg, so the
# attacks are the ones gpg itself reports: a key that has expired, a key that has been revoked, a signature of
# another key, a file changed after it was signed. Each must be refused with its own reason, while VALIDSIG alone
# (which gpg also prints for the first two) is not taken for a verdict.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=scripts/upstream/gpg-verdict.sh
. "$HERE/scripts/upstream/gpg-verdict.sh"

verdict() { local out rc; out="$(gpg_verdict "$@" 2> /dev/null)"; rc=$?; echo "$rc $out"; }

# --- the statuses as text -----------------------------------------------------------------------
FPR=0123456789ABCDEF0123456789ABCDEF01234567
good="[GNUPG:] NEWSIG
[GNUPG:] KEY_CONSIDERED $FPR 0
[GNUPG:] GOODSIG 89ABCDEF01234567 someone <s@x>
[GNUPG:] VALIDSIG $FPR 2026-11-23 1 0 4 0 22 10 00 $FPR"
check "a good signature by the pinned key is accepted" "0 " "$(verdict "$good" "$FPR")"
check "with no key pinned it is a mistake of the caller, not a verdict of anyone will do" "2 " "$(verdict "$good")"
check "and so is something that is no fingerprint" "2 " "$(verdict "$good" 1234)"
check "a good signature by another key than the pinned one is refused, and says so" "1 not made by a pinned key ($FPR)" "$(verdict "$good" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)"
check "a fingerprint that is only the beginning of the primary key's is no fingerprint" "2 " "$(verdict "$good" "${FPR%????????}")"
check "a signing subkey of the pinned key is accepted: the primary fingerprint ends the line" "0 " \
	"$(verdict "${good/VALIDSIG $FPR/VALIDSIG BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB}" "$FPR")"
two="$good
[GNUPG:] GOODSIG 1111111111111111 other <o@x>
[GNUPG:] VALIDSIG AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2026-11-23 1 0 4 0 22 10 00 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
check "two good signatures, both by pinned keys, are accepted" "0 " "$(verdict "$two" "$FPR" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)"
check "two good signatures of which one is by a key that is not pinned are refused, and the key is named" "1 not made by a pinned key (AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)" "$(verdict "$two" "$FPR")"
check "the fingerprints are compared whatever their case" "0 " "$(verdict "$good" "$(tr 'A-F' 'a-f' <<< "$FPR")")"
check "VALIDSIG alone is not a verdict" "1 no good signature" "$(verdict "[GNUPG:] VALIDSIG $FPR 2026-11-23 1 0 4 0 22 10 00 $FPR" "$FPR")"
check "nor GOODSIG alone" "1 no good signature" "$(verdict "[GNUPG:] GOODSIG 89ABCDEF01234567 someone" "$FPR")"
check "no status at all is not a verdict" "1 no good signature" "$(verdict "" "$FPR")"
for bad in BADSIG EXPSIG EXPKEYSIG REVKEYSIG KEYREVOKED ERRSIG NO_PUBKEY; do
	check "$bad beside a good signature is refused, by name" "1 $bad" "$(verdict "$good
[GNUPG:] $bad 1111111111111111 x" "$FPR")"
done
check "KEYREVOKED, which gpg prints with no argument, is refused" "1 KEYREVOKED" "$(verdict "$good
[GNUPG:] KEYREVOKED" "$FPR")"
check "a status name inside a user id is not a status" "0 " "$(verdict "[GNUPG:] GOODSIG 89ABCDEF01234567 BADSIG <x@y>
[GNUPG:] VALIDSIG $FPR 2026-11-23 1 0 4 0 22 10 00 $FPR" "$FPR")"
gpg_has_status "$good"; check "a status is noticed" 0 "$?"
gpg_has_status "gpg: command not found"; check "text that is no status is not" 1 "$?"
gpg_has_status ""; check "nor is nothing" 1 "$?"

# --- the real ones ------------------------------------------------------------------------------
command -v gpg > /dev/null || { echo "FAIL  gpg is needed for the attacks"; exit 1; }
mkdir -m 700 "$WORK/signer" "$WORK/verifier" "$WORK/other"
echo "release" > "$WORK/file"
mkkey() { # <home> <name> <expiry> [faked time]: a signing key, whose fingerprint is printed
	GNUPGHOME="$1" gpg --batch --quiet --passphrase '' ${4:+--faked-system-time "$4"} --quick-generate-key "$2 <$2@x>" ed25519 sign "$3" 2> /dev/null
	GNUPGHOME="$1" gpg --batch --with-colons --list-keys "$2@x" | awk -F: '/^fpr/ {print $10; exit}'
}
sign() { # <home> <key> <file> <signature> [faked time]
	GNUPGHOME="$1" gpg --batch --quiet --armor --detach-sign --local-user "$2" ${5:+--faked-system-time "$5"} -o "$4" "$3" 2> /dev/null
}
verify() { # <signature> <file>: the status lines, in the keyring of the verifier
	GNUPGHOME="$WORK/verifier" gpg --batch --status-fd 1 --verify "$1" "$2" 2> /dev/null
}
trust() { GNUPGHOME="$1" gpg --batch --armor --export "$2" | GNUPGHOME="$WORK/verifier" gpg --batch --quiet --import 2> /dev/null; }

good_fpr="$(mkkey "$WORK/signer" good never)"; trust "$WORK/signer" "$good_fpr"
sign "$WORK/signer" "$good_fpr" "$WORK/file" "$WORK/good.asc"
check "a file signed by the key that is pinned is accepted" "0 " "$(verdict "$(verify "$WORK/good.asc" "$WORK/file")" "$good_fpr")"

other_fpr="$(mkkey "$WORK/other" other never)"
sign "$WORK/other" "$other_fpr" "$WORK/file" "$WORK/other.asc"
check "a signature of a key the verifier does not know is refused" "1 ERRSIG" "$(verdict "$(verify "$WORK/other.asc" "$WORK/file")" "$good_fpr")"
trust "$WORK/other" "$other_fpr"
check "a good signature of another key that it does know is refused, for not being the pinned one" "1 not made by a pinned key ($other_fpr)" \
	"$(verdict "$(verify "$WORK/other.asc" "$WORK/file")" "$good_fpr")"

cp "$WORK/file" "$WORK/changed"; echo "changed after it was signed" >> "$WORK/changed"
check "a file changed after it was signed is refused" "1 BADSIG" "$(verdict "$(verify "$WORK/good.asc" "$WORK/changed")" "$good_fpr")"

# A key that expired: made in 2020 for a day, used while it was valid, checked now. gpg still prints VALIDSIG.
mkdir -m 700 "$WORK/old"
old_fpr="$(mkkey "$WORK/old" old 1d 20200101T000000)"
sign "$WORK/old" "$old_fpr" "$WORK/file" "$WORK/old.asc" 20200101T010000
trust "$WORK/old" "$old_fpr"
status="$(verify "$WORK/old.asc" "$WORK/file")"
check "the status of an expired key still holds a VALIDSIG, which is why it is not enough" "1" "$(grep -c '^\[GNUPG:\] VALIDSIG ' <<< "$status")"
check "a signature of a key that has expired is refused" "1 EXPKEYSIG" "$(verdict "$status" "$old_fpr")"

# A key that was revoked after it signed. gpg revokes a primary key only on a terminal, so the key signing is a subkey
# of a certifying primary, and the revocation of the subkey is published with the key, as a maintainer would.
mkdir -m 700 "$WORK/rev"
GNUPGHOME="$WORK/rev" gpg --batch --quiet --passphrase '' --quick-generate-key "rev <rev@x>" ed25519 cert never 2> /dev/null
rev_fpr="$(GNUPGHOME="$WORK/rev" gpg --batch --with-colons --list-keys rev@x | awk -F: '/^fpr/ {print $10; exit}')"
GNUPGHOME="$WORK/rev" gpg --batch --quiet --passphrase '' --quick-add-key "$rev_fpr" ed25519 sign never 2> /dev/null
sub_fpr="$(GNUPGHOME="$WORK/rev" gpg --batch --with-colons --list-keys --with-subkey-fingerprint rev@x | awk -F: '/^fpr/ {n++; if (n == 2) print $10}')"
sign "$WORK/rev" "$sub_fpr!" "$WORK/file" "$WORK/rev.asc"
trust "$WORK/rev" "$rev_fpr"
check "before the revocation the signature is accepted, with the primary key pinned" "0 " "$(verdict "$(verify "$WORK/rev.asc" "$WORK/file")" "$rev_fpr")"
GNUPGHOME="$WORK/rev" gpg --batch --command-fd 0 --edit-key "$rev_fpr" > /dev/null 2>&1 <<< $'key 1\nrevkey\ny\n0\n\ny\nsave\n'
trust "$WORK/rev" "$rev_fpr"
status="$(verify "$WORK/rev.asc" "$WORK/file")"
check "the status of a revoked key holds a VALIDSIG too" "1" "$(grep -c '^\[GNUPG:\] VALIDSIG ' <<< "$status")"
check "a signature of a key that was revoked is refused" "1 REVKEYSIG" "$(verdict "$status" "$rev_fpr")"

# A gpg that does not run leaves no status at all, and a bad signature leaves one: they are told apart.
check "a verifier that did not run has no status" "1" "$(gpg_has_status "$(GNUPGHOME=/nonexistent/none gpg-not-installed --verify x y 2>&1)"; echo $?)"
check "a bad signature has one" "0" "$(gpg_has_status "$(verify "$WORK/good.asc" "$WORK/changed")"; echo $?)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
