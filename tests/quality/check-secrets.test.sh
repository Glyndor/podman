#!/usr/bin/env bash
#
# Tests for scripts/quality/check-secrets.sh. The credential-shaped strings are
# assembled at run time, so this file does not trip the check it tests, and no
# value is ever printed by the script.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/quality/check-secrets.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

rep() { printf '%*s' "$2" '' | tr ' ' "$1"; } # <char> <count>

repo="$WORK/repo"
git init -q "$repo"
gitc() { git -C "$repo" -c user.name=t -c user.email=t@x -c commit.gpgSign=false "$@"; }
echo base > "$repo/README"; gitc add -A; gitc commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

# add <file> <line>: commit one new line on top of the base, then scan it.
scan() { # <line>
	git -C "$repo" reset -q --hard "$base"
	printf '%s\n' "$1" > "$repo/probe.txt"; gitc add -A; gitc commit -q -m probe
	(cd "$repo" && "$SCRIPT" "$base" HEAD 2>&1)
}

out="$(scan 'just an ordinary line')"; check "an ordinary line passes" 0 "$?"

flag() { # <description> <line> <pattern name>
	local out rc value
	value="$2"
	out="$(scan "$value")"; rc=$?
	check "$1 fails" 1 "$rc"
	check "$1 is named" 1 "$(printf '%s' "$out" | grep -c "$3")"
	check "$1 reports the file and line, not the value" 1 "$(printf '%s' "$out" | grep -c 'probe.txt:1')"
	check "$1 does not print the value" 0 "$(printf '%s' "$out" | grep -cF -- "$value")"
}

flag "a private key block" "-----BEGIN $(printf 'RSA')$(printf ' PRIVATE KEY')-----" "private key block"
flag "an AWS access key" "id AKI$(printf 'A')$(rep Q 16)" "AWS access key"
flag "a GitHub token" "t=gh$(printf 'p')_$(rep a 36)" "GitHub token"
flag "a fine-grained GitHub token" "github_pat""_$(rep b 60)" "GitHub token"
flag "a JWT" "e""yJ$(rep h 20).e""yJ$(rep p 20).sig" "JWT"
flag "a long value assigned to a secret-like name" "release_secret = \"$(rep c 40)\"" "secret-like name"
flag "a signing key assigned in a config" "SIGNING_KEY: $(rep d 43)" "secret-like name"

# Code that writes or checks the header is not a key; a key inside a string is.
out="$(scan 'let mut pem = String::from("-----BEGIN PRIVATE KEY-----\n");')"
check "code that only writes the header passes" 0 "$?"
out="$(scan '{"private_key":"-----BEGIN PRIVATE KEY-----\nMIIE...fake...\n"}')"
check "a fake key with dots passes" 0 "$?"
flag "a key body inside a string" "{\"k\":\"-----BEGIN PRIVATE KEY-----\\n$(rep M 40)\"}" "private key inside a string"

out="$(scan "api_key = \"$(rep c 40)\" # secret-scan:allow public on purpose")"
check "the allow marker skips the line" 0 "$?"

out="$(scan "token: \${{ secrets.SOMETHING_TOKEN_NAME_THAT_IS_LONG_ENOUGH_TO_MATCH }}")"
check "a reference to a CI secret passes" 0 "$?"

out="$(scan "password_file = \"/run/secrets/$(rep x 40)\"")"
check "a variable that names a file or a path passes" 0 "$?"

out="$(scan "api_key = \"your-$(rep x 40)\"")"
check "a placeholder passes" 0 "$?"

# A secret that was already in the base is not a reason to fail this change.
printf 'old_token = "%s"\n' "$(rep z 40)" > "$repo/old.txt"; gitc add -A; gitc commit -q -m "old"
base2="$(git -C "$repo" rev-parse HEAD)"
echo more >> "$repo/README"; gitc add -A; gitc commit -q -m "touch"
(cd "$repo" && "$SCRIPT" "$base2" HEAD >/dev/null 2>&1); check "an old line in the base is not rescanned" 0 "$?"

# A file that is moved, unchanged, carries its lines to a new path. With rename detection
# the diff says only "renamed" and the scan reads nothing, so what entered before the scan
# existed, or by a merge it does not read, would move for good: the scan reads a moved file
# whole. The fixture repository asks for rename detection itself, since that is what the
# default of git does and a machine's own configuration can turn it off.
git -C "$repo" config diff.renames true
mkdir -p "$repo/moved"; gitc mv old.txt moved/old.txt; gitc commit -q -m "move the old file"
out="$( (cd "$repo" && "$SCRIPT" "$base2" HEAD 2>&1) )"; rc=$?
check "a file moved unchanged is scanned whole, and a credential in it fails" 1 "$rc"
check "and it is named at its new path" 1 "$(printf '%s' "$out" | grep -c 'moved/old.txt:1 long value assigned to a secret-like name')"
check "and the moved value is not printed" 0 "$(printf '%s' "$out" | grep -cF -- "$(rep z 40)")"
base3="$(git -C "$repo" rev-parse HEAD)"
gitc mv README README.md; gitc commit -q -m "rename a harmless file"
(cd "$repo" && "$SCRIPT" "$base3" HEAD >/dev/null 2>&1); check "a harmless file moved the same way passes" 0 "$?"
gitc reset -q --hard "$base2"

# A repository lists the paths that hold throwaway keys on purpose. The list counts
# once it is on the base branch, so it is committed to the base before the change.
git -C "$repo" reset -q --hard "$base"
printf '# test keys\n\n^fixtures/\n' > "$repo/.secret-scan-allow"
gitc add -A; gitc commit -q -m "list the fixture paths"
listed="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/fixtures"
printf -- '-----BEGIN %s-----\n%s\n' 'PRIVATE KEY' "$(rep M 40)" > "$repo/fixtures/test.pem"
gitc add -A; gitc commit -q -m "fixture"
(cd "$repo" && "$SCRIPT" "$listed" HEAD >/dev/null 2>&1); check "a path listed in .secret-scan-allow on the base is skipped" 0 "$?"
printf -- '-----BEGIN %s-----\n' 'PRIVATE KEY' > "$repo/elsewhere.pem"; gitc add -A; gitc commit -q -m "elsewhere"
out="$( (cd "$repo" && "$SCRIPT" "$listed" HEAD 2>&1) )"; rc=$?
check "a key outside the listed paths still fails" 1 "$rc"
check "and it is refused as a key block" 1 "$(printf '%s' "$out" | grep -c 'elsewhere.pem:1 private key block')"

# A change cannot list its own exceptions: the same fixture with the list added by
# the change itself is scanned, and an expression that matches everything is no
# way to switch the scan off.
for list in '^fixtures/' '^.*$' '[unclosed'; do
	git -C "$repo" reset -q --hard "$base"
	mkdir -p "$repo/fixtures"
	printf -- '-----BEGIN %s-----\n' 'PRIVATE KEY' > "$repo/fixtures/test.pem"
	printf '%s\n' "$list" > "$repo/.secret-scan-allow"
	gitc add -A; gitc commit -q -m "fixture with its own list"
	out="$( (cd "$repo" && "$SCRIPT" "$base" HEAD 2>&1) )"; rc=$?
	check "a list the change brings itself ($list) is not read: it fails" 1 "$rc"
	check "and the key is named, not the list" 1 "$(printf '%s' "$out" | grep -c 'fixtures/test.pem:1 private key block')"
	check "and no complaint about the list is made" 0 "$(printf '%s' "$out" | grep -c 'secret-scan-allow line')"
done

# An expression on the base that does not compile stops the scan, whatever the change
# adds: a grep that cannot read its patterns must not be taken for a scan that found
# nothing. The same list with a valid expression is accepted.
git -C "$repo" reset -q --hard "$base"
printf '# why\n[unclosed\n' > "$repo/.secret-scan-allow"
gitc add -A; gitc commit -q -m "a list that does not compile"
broken="$(git -C "$repo" rev-parse HEAD)"
printf 'AWS_KEY=AKI%s\n' "A$(rep Q 16)" > "$repo/c.txt"; gitc add -A; gitc commit -q -m "a credential"
out="$( (cd "$repo" && "$SCRIPT" "$broken" HEAD 2>&1) )"; rc=$?
check "an expression that does not compile fails the scan" 1 "$rc"
check "and it names the line of the list" 1 "$(printf '%s' "$out" | grep -c '::error::.secret-scan-allow line 2 is not a valid regular expression')"
check "and no clean verdict is given" 0 "$(printf '%s' "$out" | grep -c 'no credential-shaped lines added')"
git -C "$repo" reset -q --hard "$broken"
printf '# why\n^docs/\n' > "$repo/.secret-scan-allow"
gitc add -A; gitc commit -q -m "a list that compiles"
valid="$(git -C "$repo" rev-parse HEAD)"
printf 'AWS_KEY=AKI%s\n' "A$(rep Q 16)" > "$repo/c.txt"; gitc add -A; gitc commit -q -m "a credential"
out="$( (cd "$repo" && "$SCRIPT" "$valid" HEAD 2>&1) )"; rc=$?
check "a list that compiles leaves the credential to be found" 1 "$rc"
check "and it is named as a credential" 1 "$(printf '%s' "$out" | grep -c 'c.txt:1 AWS access key')"

# A grep that fails while it applies a valid list must not empty the set it was
# filtering: with a grep that refuses to read a pattern file, the scan stops.
mkdir -p "$WORK/fakebin"
real_grep="$(command -v grep)"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -f ] && exit 2; done\nexec %s "$@"\n' "$real_grep" > "$WORK/fakebin/grep"
chmod +x "$WORK/fakebin/grep"
out="$( (cd "$repo" && PATH="$WORK/fakebin:$PATH" "$SCRIPT" "$valid" HEAD 2>&1) )"; rc=$?
check "a grep that fails on the list stops the scan" 1 "$rc"
check "and says nothing was scanned" 1 "$(printf '%s' "$out" | grep -c 'could not apply .secret-scan-allow, so nothing was scanned')"
check "and gives no clean verdict" 0 "$(printf '%s' "$out" | grep -c 'no credential-shaped lines added')"

# A range that cannot be taken is a failure, not a clean scan.
out="$( (cd "$repo" && "$SCRIPT" 0000000000000000000000000000000000000000 HEAD 2>&1) )"; rc=$?
check "an unreadable range fails" 1 "$rc"
check "and says nothing was scanned" 1 "$(printf '%s' "$out" | grep -c 'so nothing was scanned')"
check "and gives no clean verdict" 0 "$(printf '%s' "$out" | grep -c 'no credential-shaped lines added')"

"$SCRIPT" >/dev/null 2>&1; check "no arguments fails" 1 "$?"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
