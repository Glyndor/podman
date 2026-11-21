#!/usr/bin/env bash
#
# Tests for scripts/upstream/verify-tag.sh against throwaway keys: a tag is
# accepted only when it is annotated, signed, and the key is in the allowed set.
# Each refusal is asserted by the reason the script gives, since several of its
# checks would refuse the same tag.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/verify-tag.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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

mkdir "$WORK/empty"
"$SCRIPT" "$repo" v1.0.0 "$WORK/empty" >/dev/null 2>&1; check "no keys fails" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
