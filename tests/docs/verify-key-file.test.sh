#!/usr/bin/env bash
#
# Tests that docs/verify.md reads a key file the way the verifier does, and that what it
# says about the file is true of the files this repository commits.
#
# The page tells a reader to take the key out of the file with a short pipeline. The
# verifier skips comments and blank lines; a pipeline that only skips comments hands a
# blank line to OpenSSL as the key, and a good package then fails to verify by hand.
# So each pipeline of the page is run here over a file with a comment and a blank line
# before the key, and has to print the key.
#
# The page also says the key file is printable ASCII with line feeds and nothing else.
# That sentence is held to the committed files: every key file has to be exactly that.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$HERE/docs/verify.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# pipelines <doc>: for every line that fetches a key file, what follows the fetch.
pipelines() {
	sed -n 's/^key="\$(curl [^|]*keyring\/[a-z0-9-]*\.b64 | \(.*\))"$/\1/p' "$1"
}

KEY='HFv7vg5FCY7YyKUDbJhaQSfB9SboJGSblJtFbLmLHzM'
printf '# a comment\n\n   \n%s\n%s\n' "$KEY" 'SECONDKEYSECONDKEYSECONDKEYSECONDKEYSECONDK' > "$WORK/keys"

mapfile -t found < <(pipelines "$DOC")
check "the page fetches a key file in two places, one per signature" "2" "${#found[@]}"
for p in "${found[@]}"; do
	# The pipeline is the page's own text: it is run as the reader would run it.
	got="$(bash -c "$p" < "$WORK/keys" 2>/dev/null)"
	check "the page's pipeline ($p) skips a comment and blank lines and prints the first key" "$KEY" "$got"
done

# A pipeline that skips comments only is the defect: it prints the blank line.
got="$(bash -c "grep -v '^#' | head -n 1" < "$WORK/keys")"
check "a pipeline that skips comments only would have printed a blank line, not the key" "" "$got"

# What the page says about the file, and the files as they are.
check "the page says a key file is printable ASCII with line feeds and nothing else" "1" \
	"$(grep -c 'printable ASCII with line feeds and nothing else' "$DOC")"
outside() { LC_ALL=C tr -d ' -~\n' < "$1" | wc -c | tr -d ' '; }
for f in "$HERE"/keyring/glyndor-release-*.b64; do
	check "${f##*/} is printable ASCII with line feeds and nothing else" "0" "$(outside "$f")"
done
printf '# comment\r\n%s\r\n' "$KEY" > "$WORK/crlf"
check "and a file with two carriage returns has two bytes outside it" "2" "$(outside "$WORK/crlf")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
