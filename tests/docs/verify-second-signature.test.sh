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
#
# Whether the second signature is required is a second statement, held the same way to
# keyring/second-signature-required, in docs/verify.md and in the README.
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

# --- whether it is required is held to the switch --------------------------------
# keyring/second-signature-required holds the line "required" or it does not, and the
# release workflow requires the second signature by that line. The page and the README
# say which, each with one of two sentences, and never both.
NOT_YET='The second signature is not required yet.'
REQUIRED='The second signature is required of every release.'
claim() { # <switch file> <doc file>: what is wrong between the two, or nothing
	local on=no not_yet=no required=no
	grep -q -x 'required' "$1" && on=yes
	grep -q -F -- "$NOT_YET" "$2" && not_yet=yes
	grep -q -F -- "$REQUIRED" "$2" && required=yes
	case "$on $not_yet $required" in
		"no yes no" | "yes no yes") ;;
		no*) echo "${2##*/} must say '$NOT_YET' and only that, while the switch is off" ;;
		yes*) echo "${2##*/} must say '$REQUIRED' and only that, while the switch is on" ;;
	esac
}
for doc in docs/verify.md README.md; do
	check "$doc says whether the second signature is required as keyring/second-signature-required does" "" \
		"$(claim "$HERE/keyring/second-signature-required" "$HERE/$doc")"
done
printf '# off\n' > "$WORK/off"; printf '# on\nrequired\n' > "$WORK/on"
printf 'x %s y\n' "$NOT_YET" > "$WORK/notyet.md"; printf 'x %s y\n' "$REQUIRED" > "$WORK/required.md"
printf '%s %s\n' "$NOT_YET" "$REQUIRED" > "$WORK/both.md"; printf 'nothing\n' > "$WORK/none.md"
check "off and 'not required yet': agree" "" "$(claim "$WORK/off" "$WORK/notyet.md")"
check "on and 'required': agree" "" "$(claim "$WORK/on" "$WORK/required.md")"
check "off and a page that says required is named" "required.md must say '$NOT_YET' and only that, while the switch is off" \
	"$(claim "$WORK/off" "$WORK/required.md")"
check "on and a page that says not yet is named" "notyet.md must say '$REQUIRED' and only that, while the switch is on" \
	"$(claim "$WORK/on" "$WORK/notyet.md")"
check "a page that says both is named" "both.md must say '$NOT_YET' and only that, while the switch is off" "$(claim "$WORK/off" "$WORK/both.md")"
check "a page that says neither is named" "none.md must say '$REQUIRED' and only that, while the switch is on" "$(claim "$WORK/on" "$WORK/none.md")"

# --- what CONTRIBUTING.md says the line does, held to what release.yml does ---------
# The release requires the second signature when the line is there, when the secret is
# set, or when the newest release carries it (release.yml, the step that signs), so the
# line is one of three and taking it out alone retires nothing. The guide says so, and
# does not say the line is what retires it.
RETIRES='taking the line out is what retires the second signature'
guide() { # <file>: what is wrong with what the guide says about the line, or nothing
	local flat
	flat="$(tr '\n' ' ' < "$1" | tr -s ' ' | tr 'A-Z' 'a-z')"
	case "$flat" in *"$RETIRES"*) echo "it says taking the line out retires the second signature" ;; esac
	case "$flat" in *glyndor_release_mldsa65_key*) ;; *) echo "it does not name the secret as a second requirement" ;; esac
	case "$flat" in *"newest release"*) ;; *) echo "it does not name the newest release as a third requirement" ;; esac
}
check "CONTRIBUTING.md says what the line does and what else requires the second signature" "" "$(guide "$HERE/CONTRIBUTING.md")"
check "docs/verify.md says it too" "" "$(guide "$HERE/docs/verify.md")"
printf 'The line is one of three: the secret GLYNDOR_RELEASE_MLDSA65_KEY and the newest release also require it.\n' > "$WORK/guide-good.md"
printf 'While that line is there it is required, and taking the line\nout is what retires the second signature.\n' > "$WORK/guide-old.md"
printf 'The line requires it.\n' > "$WORK/guide-short.md"
check "a guide that names the secret and the newest release is accepted" "" "$(guide "$WORK/guide-good.md")"
check "a guide that says the line retires the signature is named" "it says taking the line out retires the second signature" "$(guide "$WORK/guide-old.md" | head -n 1)"
check "a guide that names neither other requirement is named" "it does not name the secret as a second requirement it does not name the newest release as a third requirement" \
	"$(guide "$WORK/guide-short.md" | paste -sd' ')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
