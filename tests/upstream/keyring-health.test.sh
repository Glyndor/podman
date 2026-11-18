#!/usr/bin/env bash
#
# Tests for scripts/upstream/keyring-health.sh against throwaway keys with known
# expiry: it counts the keys that can still sign inside the window.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/keyring-health.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

newkey() { # <name> <expiry>
	local home="$WORK/gh-$1"
	mkdir -m700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' --quick-gen-key "$1 <$1@x>" ed25519 sign "$2" 2>/dev/null
	GNUPGHOME="$home" gpg --batch --armor --export "$1@x" > "$WORK/keys/$1.asc"
}
mkdir "$WORK/keys"
newkey long 400d
newkey forever 0
newkey soon 10d
now="$(date +%s)"

out="$("$SCRIPT" "$WORK/keys" "$now" 60 2 2>&1)"; rc=$?
check "two keys valid past the window meet a minimum of two" 0 "$rc"
check "and the one that expires inside it is marked" 1 "$(printf '%s' "$out" | grep -c 'not valid in the window')"
check "and the count is stated" 1 "$(printf '%s' "$out" | grep -c '2 key(s) still valid')"

"$SCRIPT" "$WORK/keys" "$now" 60 3 >/dev/null 2>&1
check "a minimum of three is not met" 1 "$?"

"$SCRIPT" "$WORK/keys" "$((now + 500 * 86400))" 60 2 >/dev/null 2>&1
check "five hundred days from now the 400-day key has expired too" 1 "$?"

mkdir "$WORK/none"
"$SCRIPT" "$WORK/none" "$now" 60 1 >/dev/null 2>&1; check "no keys is exit 2" 2 "$?"
"$SCRIPT" >/dev/null 2>&1; check "no arguments fails" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
