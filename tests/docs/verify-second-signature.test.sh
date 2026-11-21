#!/usr/bin/env bash
#
# Tests that docs/verify.md says the truth about the second (ML-DSA-65) signature. It
# says releases do not carry it yet, and whether they do is not something the document
# can see: it depends on whether keyring/glyndor-release-mldsa65.b64 holds a public key.
# So the sentence is held to the file. While the file has no key the sentence has to be
# there, and from the commit that adds a key it has to be gone, which makes that commit
# rewrite the page. Without this the day the key is committed the page goes stale and
# nothing says so; a reader would be told no release is signed twice while they are.
#
# The sentence is the whole of the statement: "Releases do not carry it yet."
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

SAYS_NONE='Releases do not carry it yet.'

# verdict <anchor file> <doc file>: what is wrong between the two, or nothing.
verdict() {
	local keyed=no says=no
	grep -q -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" && keyed=yes
	grep -q -F -- "$SAYS_NONE" "$2" && says=yes
	case "$keyed $says" in
		"no yes" | "yes no") ;;
		"no no") echo "the anchor holds no key and the page no longer says releases do not carry the second signature" ;;
		"yes yes") echo "the anchor holds a key and the page still says releases do not carry the second signature" ;;
	esac
}

# The files as they are.
check "docs/verify.md and the ML-DSA-65 anchor agree about whether releases carry the second signature" "" \
	"$(verdict "$HERE/keyring/glyndor-release-mldsa65.b64" "$HERE/docs/verify.md")"

# The four combinations, so the check is seen to refuse both ways and to accept both.
printf '# comment only\n\n  # indented\n' > "$WORK/empty"
printf '# comment\nAAAAAAAAAAAAAAAA\n' > "$WORK/keyed"
printf 'Releases do not carry it yet. When they do, ...\n' > "$WORK/says"
printf 'Each release carries it, as a third file.\n' > "$WORK/silent"
check "no key and the sentence: agree" "" "$(verdict "$WORK/empty" "$WORK/says")"
check "a key and no sentence: agree" "" "$(verdict "$WORK/keyed" "$WORK/silent")"
check "a key and the sentence is named" "the anchor holds a key and the page still says releases do not carry the second signature" \
	"$(verdict "$WORK/keyed" "$WORK/says")"
check "no key and no sentence is named" "the anchor holds no key and the page no longer says releases do not carry the second signature" \
	"$(verdict "$WORK/empty" "$WORK/silent")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
