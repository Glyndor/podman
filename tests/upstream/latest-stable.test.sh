#!/usr/bin/env bash
#
# Tests for scripts/upstream/latest-stable.sh: it must pick the highest plain
# SemVer tag by version order (not text order) and never a pre-release.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/latest-stable.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkrepo() { # <dir> <tag>...
	local dir="$1"; shift
	git init -q "$dir"
	git -C "$dir" -c user.name=t -c user.email=t@x commit -q --allow-empty -m c
	for t in "$@"; do git -C "$dir" -c tag.gpgSign=false tag "$t"; done
}

mkrepo "$WORK/a" v1.2.3 v1.10.0 v1.9.9 v1.10.0-rc1 v2.0.0-rc1 nightly v1.10
check "highest stable by version order" v1.10.0 "$("$SCRIPT" "$WORK/a")"

mkrepo "$WORK/b" v6.2.0-rc1 v5.8.10
check "pre-release of a higher version is ignored" v5.8.10 "$("$SCRIPT" "$WORK/b")"

mkrepo "$WORK/c" v1.0.0-rc1 latest
"$SCRIPT" "$WORK/c" >/dev/null 2>&1; check "no stable tag fails" 1 "$?"

"$SCRIPT" "$WORK/missing" >/dev/null 2>&1; [ $? -ne 0 ]; check "unreachable repository fails" 0 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
