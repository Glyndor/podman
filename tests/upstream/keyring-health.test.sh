#!/usr/bin/env bash
#
# Tests for scripts/upstream/keyring-health.sh against throwaway keys with known
# expiry: it counts the keys that can still sign inside the window.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/keyring-health.sh"
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

# A revoked key has no expiry date, so only gpg's own verdict shows it. A key that
# gpg cannot read at all is not "too few keys" either.
mkdir "$WORK/rev"
cp "$WORK/keys/long.asc" "$WORK/keys/forever.asc" "$WORK/rev/"
newkey gone 0
home="$WORK/gh-gone"
fpr="$(GNUPGHOME="$home" gpg --batch --with-colons --list-keys gone@x | awk -F: '/^fpr/ {print $10; exit}')"
printf 'revkey\ny\n0\n\ny\nsave\n' | GNUPGHOME="$home" gpg --batch --yes --command-fd 0 --pinentry-mode loopback --edit-key "$fpr" >/dev/null 2>&1
GNUPGHOME="$home" gpg --batch --armor --export gone@x > "$WORK/rev/gone.asc"
out="$("$SCRIPT" "$WORK/rev" "$now" 60 3 2>&1)"; rc=$?
check "a revoked key does not count even though it never expires" 1 "$rc"
check "and is shown as revoked" 1 "$(printf '%s' "$out" | grep -c 'revoked')"
check "the two good keys are still counted" 1 "$(printf '%s' "$out" | grep -c '2 key(s) still valid')"

mkdir "$WORK/broken"; printf 'not a key\n' > "$WORK/broken/x.asc"
err="$("$SCRIPT" "$WORK/broken" "$now" 60 1 2>&1 >/dev/null)"; rc=$?
check "an unreadable keyring is exit 2, not too few keys, and says so" "2 1" "$rc $(printf '%s\n' "$err" | grep -c "could not import the keys under $WORK/broken")"

mkdir "$WORK/none"
err="$("$SCRIPT" "$WORK/none" "$now" 60 1 2>&1 >/dev/null </dev/null)"; rc=$?
check "no keys is exit 2, and says so" "2 1" "$rc $(printf '%s\n' "$err" | grep -c -x "no keys under $WORK/none")"
"$SCRIPT" >/dev/null 2>&1; check "no arguments fails" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
