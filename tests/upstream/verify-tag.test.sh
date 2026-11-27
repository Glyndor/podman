#!/usr/bin/env bash
#
# Tests for scripts/upstream/verify-tag.sh against throwaway keys: a tag is
# accepted only when it is annotated, signed, and the key is in the allowed set
# and neither expired nor revoked. Each refusal is asserted by the reason the
# script gives, since several of its checks would refuse the same tag.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/verify-tag.sh"
WORK="$(mktemp -d)"
# The temporary keyrings the run makes are all under $WORK, the one the script makes included: every one of them is
# closed on the way out, none of them is left running, and the folder of sockets each one made under /run goes with it.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
close_agents() {
	local dir
	for dir in "$WORK"/gh-* "$TMPDIR"/*; do
		[ -d "$dir" ] || continue
		gpgconf --homedir "$dir" --kill all > /dev/null 2>&1 || true
		gpgconf --homedir "$dir" --remove-socketdir > /dev/null 2>&1 || true
	done
}
trap 'close_agents; rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

newkey() { # <name> -> prints fingerprint, exports public key to $WORK/<name>.asc
	GNUPGHOME="$WORK/gh-$1" && export GNUPGHOME && mkdir -m700 "$GNUPGHOME"
	gpg --batch --quiet --passphrase '' --quick-gen-key "$1 <$1@x>" ed25519 sign never 2>/dev/null
	gpg --batch --armor --export "$1@x" > "$WORK/$1.asc"
	gpg --batch --with-colons --list-keys "$1@x" | awk -F: '/^fpr/ {print $10; exit}'
}

fpr_good="$(newkey good)"; gh_good="$WORK/gh-good"
fpr_other="$(newkey other)"; gh_other="$WORK/gh-other"
mkdir "$WORK/keys"; cp "$WORK/good.asc" "$WORK/keys/"

repo="$WORK/repo"
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@x commit -q --allow-empty -m c
commit="$(git -C "$repo" rev-parse HEAD)"

sign() { # <tag> <gnupghome> <fingerprint>
	GNUPGHOME="$2" git -C "$repo" -c user.name=t -c user.email=t@x -c gpg.format=openpgp -c gpg.program=gpg \
		-c user.signingkey="$3" tag -s -m "$1" "$1" >/dev/null 2>&1
}
sign v1.0.0 "$gh_good" "$fpr_good"
sign v1.0.1 "$gh_other" "$fpr_other"
git -C "$repo" -c user.name=t -c user.email=t@x -c tag.gpgSign=false tag -a -m unsigned v1.0.2
git -C "$repo" -c tag.gpgSign=false tag v1.0.3

out="$("$SCRIPT" "$repo" v1.0.0 "$WORK/keys" 2>/dev/null)"; rc=$?
check "signed by an allowed key passes" 0 "$rc"
check "prints the commit it points to" "$commit" "$out"

refused() { # <desc> <tag> <keys-dir> <reason the script must give>
	local err rc
	err="$("$SCRIPT" "$repo" "$2" "$3" 2>&1 >/dev/null)"; rc=$?
	check "$1 fails" 1 "$rc"
	check "$1 fails for the reason: $4" 1 "$(printf '%s\n' "$err" | grep -c -F -- "$4")"
}
refused "signed by an unknown key" v1.0.1 "$WORK/keys" "rejected: ERRSIG"
# The keyring that decides is the one built here from the allowed keys, never the caller's:
# a developer's machine or a runner of their own has keys of its own. Here the caller's
# GNUPGHOME holds the key that signed v1.0.1, which is not in the allowed set, and the
# answer has to stay the refusal of the case above. Paired with the same variable set to a
# keyring that holds the allowed key, which passes either way.
err="$(GNUPGHOME="$gh_other" "$SCRIPT" "$repo" v1.0.1 "$WORK/keys" 2>&1 >/dev/null)"; rc=$?
check "a tag signed by a key in the caller's own keyring, and not in the allowed set, fails" 1 "$rc"
check "and for the reason that the key is not one of the allowed" 1 "$(printf '%s\n' "$err" | grep -c -F -- "rejected: ERRSIG")"
GNUPGHOME="$gh_good" "$SCRIPT" "$repo" v1.0.0 "$WORK/keys" >/dev/null 2>&1; check "with the caller's GNUPGHOME set to another keyring, a tag of an allowed key passes" 0 "$?"
check "and the caller's keyring is left as it was" 1 "$([ -d "$gh_good" ] && [ -d "$gh_other" ] && echo 1 || echo 0)"
refused "annotated but unsigned" v1.0.2 "$WORK/keys" "has no good signature"
refused "lightweight tag" v1.0.3 "$WORK/keys" "is not an annotated tag"
# A lightweight tag on a commit whose message has a "tag v1.0.4" line would get past
# the check of the name inside the object, so the reason has to be the tag's type.
git -C "$repo" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "c" -m "tag v1.0.4"
git -C "$repo" -c tag.gpgSign=false tag v1.0.4
refused "lightweight tag whose commit names it" v1.0.4 "$WORK/keys" "is not an annotated tag"

# A ref renamed onto an older signed tag object: the signature is genuine, the
# name is not the one the object was signed under.
git -C "$repo" update-ref refs/tags/v1.0.9 "$(git -C "$repo" rev-parse refs/tags/v1.0.0)"
err="$("$SCRIPT" "$repo" v1.0.9 "$WORK/keys" 2>&1 >/dev/null)"; rc=$?
check "a signed tag object under another name fails" 1 "$rc"
check "and says which name the object carries" 1 "$(printf '%s' "$err" | grep -c "named 'v1.0.0'")"

# A key file that does not import stops the check with gpg's own status and says why;
# the allowed key beside it does not make the tag pass. The same allowed key alone passes.
mkdir "$WORK/keys-torn"; cp "$WORK/good.asc" "$WORK/keys-torn/"
head -c 200 "$WORK/other.asc" > "$WORK/keys-torn/torn.asc"
err="$("$SCRIPT" "$repo" v1.0.0 "$WORK/keys-torn" 2>&1 >/dev/null)"; rc=$?
check "a key file that does not import fails with the status gpg gives" 2 "$rc"
check "and says which keys could not be imported" 1 "$(printf '%s\n' "$err" | grep -c -F -- "could not import the keys under $WORK/keys-torn")"
check "and passes on what gpg said" 1 "$([ "$(printf '%s\n' "$err" | wc -l)" -ge 2 ] && echo 1 || echo 0)"
accepted_alone="$("$SCRIPT" "$repo" v1.0.0 "$WORK/keys" 2>&1)"; check "the allowed key alone still passes" "$commit" "$accepted_alone"

mkdir "$WORK/empty"
"$SCRIPT" "$repo" v1.0.0 "$WORK/empty" >/dev/null 2>&1; check "no keys fails" 1 "$?"

# The tags below are written by hand, so the signature can be made at a chosen time
# or by more than one key. Each refusal is paired with an acceptance of the same shape.
signed_tag() { # <tag> <gnupghome> <gpg option>...: signs a tag object for $commit and points refs/tags/<tag> at it
	local tag="$1" home="$2"; shift 2
	printf 'object %s\ntype commit\ntag %s\ntagger t <t@x> 1700000000 +0000\n\n%s\n' "$commit" "$tag" "$tag" > "$WORK/payload"
	GNUPGHOME="$home" gpg --batch --quiet --yes --armor --detach-sign -o "$WORK/payload.asc" "$@" "$WORK/payload" 2>/dev/null
	git -C "$repo" update-ref "refs/tags/$tag" "$(cat "$WORK/payload" "$WORK/payload.asc" | git -C "$repo" mktag)"
}
accepted() { # <desc> <tag> <keys-dir>
	local out
	out="$("$SCRIPT" "$repo" "$2" "$3" 2>/dev/null)"
	check "$1 passes" "$commit" "$out"
}

# Expired: a key made in 2020 that lasted a week, used while it was valid. gpg reports
# EXPKEYSIG for it and no GOODSIG. A key that expires next year is the acceptance.
mkdir -m700 "$WORK/gh-short" "$WORK/gh-later" "$WORK/keys-dated"
GNUPGHOME="$WORK/gh-short" gpg --batch --quiet --faked-system-time 20200101T000000 \
	--passphrase '' --quick-gen-key "short <short@x>" ed25519 sign 1w 2>/dev/null
GNUPGHOME="$WORK/gh-later" gpg --batch --quiet --passphrase '' --quick-gen-key "later <later@x>" ed25519 sign 1y 2>/dev/null
GNUPGHOME="$WORK/gh-short" gpg --batch --armor --export short@x 2>/dev/null > "$WORK/keys-dated/short.asc"
GNUPGHOME="$WORK/gh-later" gpg --batch --armor --export later@x 2>/dev/null > "$WORK/keys-dated/later.asc"
signed_tag v2.0.0 "$WORK/gh-short" --faked-system-time 20200102T000000 -u short@x
signed_tag v2.0.1 "$WORK/gh-later" -u later@x
refused "signed by a key that has expired" v2.0.0 "$WORK/keys-dated" "rejected: EXPKEYSIG"
accepted "signed by a key that has not expired yet" v2.0.1 "$WORK/keys-dated"

# Revoked: the same key and the same tag, before and after the key is revoked.
mkdir -m700 "$WORK/gh-gone"; mkdir "$WORK/keys-before" "$WORK/keys-revoked"
GNUPGHOME="$WORK/gh-gone" gpg --batch --quiet --passphrase '' --quick-gen-key "gone <gone@x>" ed25519 sign never 2>/dev/null
GNUPGHOME="$WORK/gh-gone" gpg --batch --armor --export gone@x 2>/dev/null > "$WORK/keys-before/gone.asc"
signed_tag v2.1.0 "$WORK/gh-gone" -u gone@x
fpr_gone="$(GNUPGHOME="$WORK/gh-gone" gpg --batch --with-colons --list-keys gone@x 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')"
printf 'revkey\ny\n0\n\ny\nsave\n' | GNUPGHOME="$WORK/gh-gone" gpg --batch --yes --command-fd 0 --pinentry-mode loopback --edit-key "$fpr_gone" >/dev/null 2>&1
GNUPGHOME="$WORK/gh-gone" gpg --batch --armor --export gone@x 2>/dev/null > "$WORK/keys-revoked/gone.asc"
accepted "signed by a key before it was revoked" v2.1.0 "$WORK/keys-before"
refused "signed by a key that was revoked since" v2.1.0 "$WORK/keys-revoked" "rejected: REVKEYSIG"

# Two signatures on one tag: gpg reports each, so one from an allowed key and one from
# a key that is not allowed gives a GOODSIG and an ERRSIG together. That is the case
# the list of bad codes decides; with only one signature GOODSIG decides alone.
GNUPGHOME="$gh_good" gpg --batch --pinentry-mode loopback --passphrase '' --export-secret-keys good@x \
	| GNUPGHOME="$gh_other" gpg --batch --quiet --import 2>/dev/null
GNUPGHOME="$WORK/gh-later" gpg --batch --pinentry-mode loopback --passphrase '' --export-secret-keys later@x \
	| GNUPGHOME="$gh_other" gpg --batch --quiet --import 2>/dev/null
mkdir "$WORK/keys-two"; cp "$WORK/good.asc" "$WORK/keys-dated/later.asc" "$WORK/keys-two/"
signed_tag v2.2.0 "$gh_other" -u "$fpr_good" -u "$fpr_other"
signed_tag v2.2.1 "$gh_other" -u "$fpr_good" -u later@x
refused "signed by an allowed key and by one that is not" v2.2.0 "$WORK/keys-two" "rejected: ERRSIG"
# git itself exits 1 for a tag with two signatures, whatever their keys, and its exit status is respected: a tag
# signed twice is refused, and the reason says so. Upstream signs its tags once.
refused "signed by two allowed keys" v2.2.1 "$WORK/keys-two" "rejected: git verify-tag exited 1"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
