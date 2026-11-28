#!/usr/bin/env bash
#
# Tests for scripts/release/check-upload.sh: the artifact a build job reported has to be in the list of the run, by its
# id, under its name, unexpired, made for the commit and with the digest reported.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/release/check-upload.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

SHA=0123456789abcdef0123456789abcdef01234567
H1="$(printf 'a%.0s' $(seq 1 64))"; H2="$(printf 'b%.0s' $(seq 1 64))"
list() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" > "$WORK/list"; }
good() { list rpm-set 14 false "$SHA" "sha256:$H1"; }
up() { out="$(bash "$SCRIPT" "${1-rpm-set}" "${2-14}" "${3-$H1}" "${4-$SHA}" "${5-$WORK/list}" 2>&1)"; rc=$?; }
refused() { check "$1" "1 1" "$rc $(says "$2")"; }

good; up
check "the artifact the build reported: taken, and said" "0 1" "$rc $(says "rpm-set is artifact 14, sha256:$H1")"
up rpm-set 14 "sha256:$H1"
check "a digest written with its prefix is the same digest" 0 "$rc"
for id in "" x '14; id' -1; do up rpm-set "$id"; refused "the id '$id' is not a number" "reported the artifact id '$id', not a number"; done
for digest in "" abc "${H1}0" "sha256:"; do up rpm-set 14 "$digest"; refused "the digest '$digest' is not a sha256" "not a sha256"; done
for commit in "" main "${SHA%?}"; do up rpm-set 14 "$H1" "$commit"; refused "the commit '$commit' is not a full commit id" "is not a full commit id"; done
up rpm-set 14 "$H1" "$SHA" "$WORK/absent"
refused "no list of the artifacts" "there is no list"
up rpm-set 99
refused "an id the run does not list" "does not list exactly one artifact with the id 99"
printf 'rpm-set\t14\tfalse\t%s\tsha256:%s\nrpm-set\t14\tfalse\t%s\tsha256:%s\n' "$SHA" "$H1" "$SHA" "$H1" > "$WORK/list"; up
refused "an id listed twice" "does not list exactly one artifact with the id 14"
list rpmcheck-set 14 false "$SHA" "sha256:$H1"; up
refused "an artifact of another name" "the artifact 14 is called rpmcheck-set, not rpm-set"
list rpm-set 14 true "$SHA" "sha256:$H1"; up
refused "an expired artifact" "rpm-set has expired"
list rpm-set 14 false feedfacefeedfacefeedfacefeedfacefeedface "sha256:$H1"; up
refused "an artifact made for another commit" "rpm-set was made for feedface"
list rpm-set 14 false "$SHA" "sha256:$H2"; up
refused "a digest that differs from the one reported" "gives rpm-set the digest 'sha256:$H2'"
list rpm-set 14 false "$SHA" ""; up
refused "a list with no digest" "gives rpm-set the digest ''"
bash "$SCRIPT" rpm-set 14 > /dev/null 2>&1; check "too few arguments is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
