#!/usr/bin/env bash
#
# Tests for .github/scripts/release/dry-run-keys.py, which makes the throwaway keys of a rehearsal of the
# release: the keys it writes sign and verify with the real tools, the seeds are readable by their owner only,
# and it refuses a directory that exists, a path that is a link, and arguments it does not know.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/.github/scripts/release/dry-run-keys.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
run() { python3 -I "$SCRIPT" "$@" > "$WORK/out" 2>&1; rc=$?; }

run "$WORK/ed"
check "with no option it makes the Ed25519 key" "0 ed25519.b64 ed25519.seed" "$rc $(ls "$WORK/ed" | paste -sd' ')"
check "and the seed is readable by its owner only" "600" "$(stat -c %a "$WORK/ed/ed25519.seed")"
check "and nothing is printed, so no seed reaches a log" "" "$(cat "$WORK/out")"

# What the keys are for: sign.py signs with the seed and verify-sig.py accepts it against the anchor.
echo hello > "$WORK/f"
GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/ed/ed25519.seed")" python3 -I "$HERE/.github/scripts/release/sign.py" "$WORK/f" > /dev/null 2>&1
python3 -I "$HERE/.github/scripts/release/verify-sig.py" "$WORK/f" "$WORK/f.sig" "$WORK/ed/ed25519.b64" > /dev/null 2>&1
check "the file signed with the throwaway seed verifies against its anchor" "0" "$?"
python3 -I "$HERE/.github/scripts/release/verify-sig.py" "$WORK/f" "$WORK/f.sig" "$HERE/keyring/glyndor-release-ed25519.b64" > /dev/null 2>&1
check "and does not verify against the real anchor" "1" "$?"

run "$WORK/ed"
check "a directory that exists is refused" "1" "$rc"
ln -s "$WORK/target" "$WORK/link"
run "$WORK/link"
check "a path that is a link is not followed" "0" "$([ -d "$WORK/target" ] && echo 1 || echo 0)"
run
check "no directory is a usage error" "2" "$rc"
run "$WORK/a" "$WORK/b"
check "two directories are a usage error" "2" "$rc"

if python3 -c 'from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey' 2> /dev/null; then
	run "$WORK/pq" --mldsa
	check "with --mldsa it makes the second key too" "0 ed25519.b64 ed25519.seed mldsa65.b64 mldsa65.seed" "$rc $(ls "$WORK/pq" | paste -sd' ')"
	check "and that seed is private as well" "600" "$(stat -c %a "$WORK/pq/mldsa65.seed")"
	GLYNDOR_RELEASE_ED25519_KEY="$(cat "$WORK/pq/ed25519.seed")" GLYNDOR_RELEASE_MLDSA65_KEY="$(cat "$WORK/pq/mldsa65.seed")" \
		python3 -I "$HERE/.github/scripts/release/sign.py" "$WORK/f" > /dev/null 2>&1
	python3 -I "$HERE/.github/scripts/release/verify-sig.py" "$WORK/f" "$WORK/f.sig" "$WORK/pq/ed25519.b64" \
		--mldsa-sig "$WORK/f.mldsa65.sig" --mldsa-keys "$WORK/pq/mldsa65.b64" --require-mldsa > /dev/null 2>&1
	check "and both signatures verify against the throwaway anchors" "0" "$?"
else
	echo "skip  the second key: this python has no cryptography with ML-DSA-65 (the CI has it)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
