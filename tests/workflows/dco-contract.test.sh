#!/usr/bin/env bash
#
# Tests for the two steps of .github/workflows/reusable-dco.yml. Each is read out of
# the workflow and run, under the shell GitHub uses, inside throwaway git
# repositories, so what is judged is the step that runs on a pull request and not a
# copy of its logic.
#
# "Verify Signed-off-by trailers" has to refuse a commit with no trailer, an empty
# one and one with no address, accept a real one, refuse a range it cannot list
# instead of reporting success over nothing, and leave merge commits to the other
# step. "Detect evil merges" has to accept a clean merge and refuse one that carries
# a change that is in neither parent, an octopus and a merge it cannot recompute.
# Each refusal is told apart by its own message, and each has an accepted case of the
# same shape beside it.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0; rc=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

# A repository that does not read the machine's git configuration: no signing, no
# hooks, one identity.
export LC_ALL=C GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="A Person" GIT_AUTHOR_EMAIL="person@example.org"
export GIT_COMMITTER_NAME="A Person" GIT_COMMITTER_EMAIL="person@example.org"

SIGN=$'\n\nSigned-off-by: A Person <person@example.org>'

SD="$WORK/steps"
step reusable-dco.yml dco name="Verify Signed-off-by trailers" "$SD/trailers" || fail=$((fail + 1))
step reusable-dco.yml dco name="Detect evil merges" "$SD/merges" || fail=$((fail + 1))
check "the trailer step has no expression in its run block" 0 "$(grep -c '\${{' "$SD/trailers/run.sh")"
check "the merge step has no expression in its run block" 0 "$(grep -c '\${{' "$SD/merges/run.sh")"

# fresh <name>: an empty repository with one base commit; sets R and BASE.
fresh() {
	R="$WORK/$1"; mkdir -p "$R"
	git -C "$R" init -q -b main
	git -C "$R" commit -q --allow-empty -m "base$SIGN"
	BASE="$(git -C "$R" rev-parse HEAD)"
}
# commit <message>: an empty commit on the current branch.
commit() { git -C "$R" commit -q --allow-empty -m "$1"; }
head_of() { git -C "$R" rev-parse HEAD; }
# on <step> [BASE_SHA]: runs a step over BASE..HEAD of $R.
on() {
	run_step "$SD/$1" "$R" "BASE_SHA=${2:-$BASE}" "HEAD_SHA=$(head_of)"
}
OK_MSG="All commits carry a Signed-off-by trailer."
NO_MSG="is missing a Signed-off-by trailer"

# --- a real trailer ---------------------------------------------------------------
fresh signed
commit "feat: a change$SIGN"
on trailers
check "a commit with a real trailer is accepted" "0:1" "$rc:$(says "$OK_MSG")"

fresh unsigned
commit "feat: a change"
on trailers
check "a commit with no trailer is refused" "1:1:0" "$rc:$(says "$NO_MSG"):$(says "$OK_MSG")"
check "and it is named by its hash" 1 "$(says "commit $(head_of) ")"

fresh empty
commit "feat: a change"$'\n\nSigned-off-by:'
on trailers
check "an empty Signed-off-by is refused for the missing trailer" "1:1:0" "$rc:$(says "$NO_MSG"):$(says "$OK_MSG")"

fresh nameonly
commit "feat: a change"$'\n\nSigned-off-by: A Person'
on trailers
check "a trailer with a name and no address is refused for the missing trailer" "1:1:0" "$rc:$(says "$NO_MSG"):$(says "$OK_MSG")"

fresh addronly
commit "feat: a change"$'\n\nSigned-off-by: <person@example.org>'
on trailers
check "a trailer with an address and no name is refused for the missing trailer" "1:1:0" "$rc:$(says "$NO_MSG"):$(says "$OK_MSG")"

# --- every commit of the range ----------------------------------------------------
fresh two
commit "feat: first$SIGN"
commit "feat: second"
SECOND="$(head_of)"
on trailers
check "two commits where only the first has a trailer are refused" "1:1:0" "$rc:$(says "$NO_MSG"):$(says "$OK_MSG")"
check "and the one named is the second" 1 "$(says "commit $SECOND ")"

fresh twosigned
commit "feat: first$SIGN"
commit "feat: second$SIGN"
on trailers
check "two commits that both have one are accepted" "0:1" "$rc:$(says "$OK_MSG")"

# --- merge commits are the other step's ------------------------------------------
fresh merged
git -C "$R" checkout -q -b topic
commit "feat: on the topic$SIGN"
git -C "$R" checkout -q main
commit "feat: on main$SIGN"
git -C "$R" merge -q --no-ff -m "Merge topic" topic
check "the fixture ends in a merge commit with no trailer" "Merge topic:0" \
	"$(git -C "$R" log -1 --format=%s):$(git -C "$R" log -1 --format=%B | grep -c 'Signed-off-by')"
on trailers
check "a merge commit with no trailer inside the range is accepted by this step" "0:1" "$rc:$(says "$OK_MSG")"

# --- a range that cannot be listed ------------------------------------------------
fresh nobase
commit "feat: a change$SIGN"
MISSING="0123456789abcdef0123456789abcdef01234567"
on trailers "$MISSING"
check "a base that is not in the clone is refused, saying it could not list" "1:1" "$rc:$(says "could not list $MISSING")"
check "and the success message is not printed over nothing" 0 "$(says "$OK_MSG")"

# --- evil merges ------------------------------------------------------------------
# two_sides: topic and main each add a file; leaves $R on main with both unmerged.
two_sides() {
	fresh "$1"
	git -C "$R" checkout -q -b topic
	echo t > "$R/topic.txt"; git -C "$R" add topic.txt; commit "feat: topic$SIGN"
	git -C "$R" checkout -q main
	echo m > "$R/main.txt"; git -C "$R" add main.txt; commit "feat: main$SIGN"
}
CLEAN="No evil merges found."

two_sides cleanmerge
git -C "$R" merge -q --no-ff -m "Merge topic" topic
on merges
check "a merge that is the clean merge of its parents is accepted" "0:1" "$rc:$(says "$CLEAN")"

fresh nomerge
commit "feat: a change$SIGN"
on merges
check "a range with no merge commit is accepted" "0:1" "$rc:$(says "$CLEAN")"

two_sides evilmerge
git -C "$R" merge -q --no-ff --no-commit topic >/dev/null 2>&1
echo smuggled > "$R/smuggled.txt"; git -C "$R" add smuggled.txt
git -C "$R" commit -q -m "Merge topic"
on merges
check "a merge with a change that is in neither parent is refused for its tree" "1:1:0" \
	"$rc:$(says "introduces changes present in neither parent"):$(says "$CLEAN")"
check "and the merge is named" 1 "$(says "merge commit $(head_of)'s tree")"

fresh octopus
for b in one two three; do
	git -C "$R" checkout -q -b "$b" main
	echo "$b" > "$R/$b.txt"; git -C "$R" add "$b.txt"; commit "feat: $b$SIGN"
done
git -C "$R" checkout -q main
commit "feat: on main$SIGN"
git -C "$R" merge -q --no-ff -m "Merge three" one two three >/dev/null 2>&1
on merges
check "an octopus merge is refused for its parents" "1:1:0" "$rc:$(says "has 4 parents"):$(says "$CLEAN")"

fresh conflicted
echo base > "$R/f.txt"; git -C "$R" add f.txt; commit "feat: file$SIGN"
BASE="$(head_of)"
git -C "$R" checkout -q -b topic
echo topic > "$R/f.txt"; git -C "$R" commit -q -a -m "feat: topic$SIGN"
git -C "$R" checkout -q main
echo main > "$R/f.txt"; git -C "$R" commit -q -a -m "feat: main$SIGN"
git -C "$R" merge -q --no-ff --no-commit topic >/dev/null 2>&1
echo resolved > "$R/f.txt"; git -C "$R" add f.txt
git -C "$R" commit -q -m "Merge topic"
on merges
check "a merge that had to be resolved by hand is refused as unverifiable" "1:1:0" \
	"$rc:$(says "cannot be automatically verified"):$(says "$CLEAN")"

two_sides nomergebase
git -C "$R" merge -q --no-ff -m "Merge topic" topic
on merges "$MISSING"
check "a base that is not in the clone fails the merge step, saying it could not enumerate" "1:1:0" \
	"$rc:$(says "could not enumerate merge commits"):$(says "$CLEAN")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
