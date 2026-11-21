#!/usr/bin/env bash
#
# Tests for scripts/quality/check-folder-size.sh, the gate that fails when a folder
# holds more than twenty tracked files directly. Each case is a real git index in a
# throwaway repository, and a refusal is asserted by what it names, beside a case
# just inside the limit that passes, so a tree refused for another reason cannot
# pass for the one under test.
#
# Requires: git.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$HERE/scripts/quality/check-folder-size.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# run <desc> <want-exit> <needle|-> <repo>: needle must be in the output, or "-" for none
run() {
	local desc="$1" want="$2" needle="$3" repo="$4" got=0 out
	out="$(bash "$GATE" "$repo" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && { [ "$needle" = - ] || printf '%s' "$out" | grep -qF -- "$needle"; }; then
		echo "ok   - $desc (exit $got)"; pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got: $out)"
		fail=$((fail + 1))
	fi
}

# repo <name> <folder:count>...: a repository with that many tracked files in each folder
repo() {
	local name="$1" spec dir n i
	shift
	rm -rf "${WORK:?}/$name"; mkdir -p "$WORK/$name"
	git -C "$WORK/$name" init -q
	for spec in "$@"; do
		dir="${spec%%:*}"; n="${spec##*:}"
		mkdir -p "$WORK/$name/$dir"
		for ((i = 1; i <= n; i++)); do : > "$WORK/$name/$dir/f$i.txt"; done
	done
	git -C "$WORK/$name" add -A
}

repo inside docs:20
run "twenty files in a folder are inside the limit" 0 "no folder holds more than 20" "$WORK/inside"

repo over docs:21
run "twenty-one files in a folder are refused" 1 "docs holds 21 files directly" "$WORK/over"

repo deep a:20 a/b:20 a/b/c:20
run "only the files directly inside a folder count, so a tree of full folders passes" 0 - "$WORK/deep"

repo deepover a:1 a/b:21
run "a folder past the limit is named by its whole path" 1 "a/b holds 21 files directly" "$WORK/deepover"

repo root .:21
run "the root folder counts too" 1 ". holds 21 files directly" "$WORK/root"

repo two docs:21 tests:22
run "every folder over the limit is named, not only the first" 1 "tests holds 22 files directly" "$WORK/two"
run "and the other one too" 1 "docs holds 21 files directly" "$WORK/two"

repo flat .github/workflows:25
run "the workflows folder is flat for GitHub and is left out" 0 - "$WORK/flat"
repo flatother .github/other:25
run "but another folder under .github is counted" 1 ".github/other holds 25 files directly" "$WORK/flatother"

repo fixtures tests/testdata:30 tests/testdata/x:30
run "a testdata folder is left out, and so is what is under it" 0 - "$WORK/fixtures"
repo notfixtures tests/testdatas:30
run "a folder only named like it is counted" 1 "tests/testdatas holds 30 files directly" "$WORK/notfixtures"

repo untracked docs:20
: > "$WORK/untracked/docs/new.txt"
run "a file that git does not track is not counted" 0 - "$WORK/untracked"
git -C "$WORK/untracked" add -A
run "and is counted once it is added" 1 "docs holds 21 files directly" "$WORK/untracked"

mkdir "$WORK/plain"
run "a folder that is not a git working tree is refused, not read as empty" 1 "is not a git working tree" "$WORK/plain"

# A copy of the tree made without its git metadata (git archive) has nothing to count, so
# the case says it was not run instead of passing or failing for it.
if git -C "$HERE" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
	run "this repository holds the limit it checks" 0 "no folder holds more than 20" "$HERE"
else
	echo "skip - this repository holds the limit it checks: not run, this tree has no git metadata"
fi

echo
echo "passed $pass, failed $fail"
echo "DONE check-folder-size.test.sh $pass $fail"
[ "$fail" -eq 0 ]
