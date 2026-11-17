#!/usr/bin/env bash
#
# Tests for scripts/upstream/verify-tag.sh against throwaway keys: a tag is
# accepted only when it is annotated, signed, and the key is in the allowed set.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/verify-tag.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want-exit> <got-exit>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want exit $2, got $3)"; fi
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

"$SCRIPT" "$repo" v1.0.1 "$WORK/keys" >/dev/null 2>&1; check "signed by an unknown key fails" 1 "$?"
"$SCRIPT" "$repo" v1.0.2 "$WORK/keys" >/dev/null 2>&1; check "annotated but unsigned fails" 1 "$?"
"$SCRIPT" "$repo" v1.0.3 "$WORK/keys" >/dev/null 2>&1; check "lightweight tag fails" 1 "$?"

mkdir "$WORK/empty"
"$SCRIPT" "$repo" v1.0.0 "$WORK/empty" >/dev/null 2>&1; check "no keys fails" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
