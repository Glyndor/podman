#!/usr/bin/env bash
#
# The `suites` mode of scripts/quality/scope/ci-job-scope.sh decides which suites a
# pull request can affect. A wrong skip lets a change merge untested, so most of
# the cases here plant a way to slip through and require every suite to run, and
# the few that require a skip only mean something because those prove the
# resolver can tell. Every repository below is real git: a base commit, a
# branch, and the merge commit GitHub would build (HEAD with two parents).
#
# The map this repository ships is under test in
# tests/quality/scope/suite-scope-map.test.sh, and the step of tests.yml that
# uses the decision is under test in
# tests/quality/scope/ci-job-scope-suites.test.sh.
#
# Requires: bash, git, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RESOLVER="$HERE/scripts/quality/scope/ci-job-scope.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

SUITES="tests/a/one.test.sh tests/b/two.test.sh tests/c/three.test.sh"
MAP=$'tests/a/one.test.sh\n\tscripts/a/**\n\ttests/a/**\n\ntests/b/two.test.sh\n\tscripts/b/**\n\tREADME.md\n\ttests/b/two.test.sh\n'
# Note: tests/c/three.test.sh has no entry, so it must always run.

# repo <name>: a base commit with the map and the resolver, and the checkout on
# a branch ready to take the pull request's changes.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/scripts/a" "$R/scripts/b" "$R/tests/a" "$R/tests/b" "$R/tests/c" "$R/.github/workflows"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$RESOLVER" "$R/scripts/quality/scope/ci-job-scope.sh"
	printf '%s' "$MAP" > "$R/scripts/quality/scope/suite-scope.txt"
	printf 'x\n' > "$R/scripts/a/x.sh"; printf 'x\n' > "$R/scripts/b/y.sh"; printf 'readme\n' > "$R/README.md"
	printf 'docs\n' > "$R/DOCS.md"; printf 'x\n' > "$R/tests/a/one.test.sh"; printf 'x\n' > "$R/tests/b/two.test.sh"; printf 'x\n' > "$R/tests/c/three.test.sh"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# base_map <content>: change the map in the BASE (main), not in the pull
# request, and branch the pull request from there. "-" removes the map.
base_map() {
	git -C "$R" checkout -q main
	if [ "$1" = "-" ]; then git -C "$R" rm -q scripts/quality/scope/suite-scope.txt
	else printf '%s' "$1" > "$R/scripts/quality/scope/suite-scope.txt"; fi
	git -C "$R" add -A; git -C "$R" commit -qm "base map"
	git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
}
# merge: commit the pending changes on the branch and build the merge commit.
merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# decide [<path-prefix>]: the suites kept out of $SUITES, space-separated, in
# the order given. $SUITES is a list of plain words, so it is expanded unquoted
# on purpose. The optional prefix goes in front of PATH, so a case can run the
# resolver with a git of its own.
decide() {
	# shellcheck disable=SC2086
	( cd "$R" && PATH="${1:+$1:}$PATH" bash scripts/quality/scope/ci-job-scope.sh suites $SUITES 2>/dev/null | tr '\n' ' ' | sed 's/ $//' )
}
# sabotage <file> <old> <new>: replace one piece of a file and stop loudly if
# it is not there exactly once, so a case cannot pass because the sabotage did
# not land. It is the control of the cases below: the case says what the
# resolver does, and the sabotage says what it does without the protection.
sabotage() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("the sabotage target is not there exactly once: %r" % (old,))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

ALL="$SUITES"

# --- the decision says which suites can be affected ----------------------------

repo docs; echo more >> "$R/DOCS.md"; merge
check "a change no entry covers skips every mapped suite, and the unmapped one still runs" \
	"tests/c/three.test.sh" "$(decide)"

repo area; echo more >> "$R/scripts/a/x.sh"; merge
check "a change under one area runs that area's suite and the unmapped one" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

repo exact; echo more >> "$R/README.md"; merge
check "an exact file entry matches that file" \
	"tests/b/two.test.sh tests/c/three.test.sh" "$(decide)"

repo dots; echo more >> "$R/scripts/ax.sh"; mkdir -p "$R/scripts/ab"; echo y > "$R/scripts/ab/z.sh"; merge
check "a sibling directory whose name only starts like the area does not match it" \
	"tests/c/three.test.sh" "$(decide)"

repo space; mkdir -p "$R/scripts/a/sub dir"; echo y > "$R/scripts/a/sub dir/a b.sh"; merge
check "a path with spaces under ** is matched" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

repo spelling; echo more >> "$R/scripts/a/x.sh"; merge
check "the workflow's ./ spelling is normalised" \
	"tests/a/one.test.sh tests/c/three.test.sh" \
	"$( ( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh suites ./tests/a/one.test.sh ./tests/b/two.test.sh ./tests/c/three.test.sh | tr '\n' ' ' | sed 's/ $//' ) )"

# A suite whose entry does not list its own file still runs when only that file
# changes. The control is the resolver without the condition.
SELF_MAP=$'tests/d/four.test.sh\n\tscripts/d/**\n'
repo self
git -C "$R" checkout -q main; mkdir -p "$R/tests/d"; printf 'x\n' > "$R/tests/d/four.test.sh"
git -C "$R" add -A; git -C "$R" commit -qm "the suite"
base_map "$SELF_MAP"
echo more >> "$R/tests/d/four.test.sh"; merge
SUITES="tests/d/four.test.sh"
check "a suite whose entry omits its own file still runs when only it changes" \
	"tests/d/four.test.sh" "$(decide)"
sed 's/if candidate in paths or affects/if affects/' "$RESOLVER" > "$WORK/resolver-cut.sh"
check "the sabotage changed the resolver" "1" "$(cmp -s "$RESOLVER" "$WORK/resolver-cut.sh" && echo 0 || echo 1)"
cp "$WORK/resolver-cut.sh" "$R/scripts/quality/scope/ci-job-scope.sh"
check "without the condition that suite is skipped (the run is the condition's)" \
	"" "$(decide)"
SUITES="tests/a/one.test.sh tests/b/two.test.sh tests/c/three.test.sh"

# --- the things a pull request must not be able to do to its own scope ---------

repo map; printf 'tests/a/one.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"; merge
check "a pull request that rewrites the map runs every suite" "$ALL" "$(decide)"

repo resolver; echo '# edited' >> "$R/scripts/quality/scope/ci-job-scope.sh"; merge
check "a pull request that edits the resolver runs every suite" "$ALL" "$(decide)"

repo workflow; mkdir -p "$R/.github/workflows"; echo 'name: x' > "$R/.github/workflows/called.yml"; merge
check "a pull request that adds a workflow runs every suite" "$ALL" "$(decide)"

repo workflowedit; echo 'name: x' > "$R/.github/workflows/called.yml"; git -C "$R" add -A
git -C "$R" commit -qm "the workflow"; echo 'name: y' >> "$R/.github/workflows/called.yml"; merge
check "a pull request that edits a workflow runs every suite" "$ALL" "$(decide)"

# --- what every suite stands on runs every suite ---------------------------------
#
# None of these paths is in an entry of the map of these cases, so what runs the
# suites is the rule of the resolver and nothing else. The control of each is
# the resolver without that part of the rule.

# shared_case <name> <path>: a pull request that adds the path runs every suite.
shared_case() {
	repo "$1"; mkdir -p "$R/$(dirname "$2")"; echo more >> "$R/$2"; merge
	check "a change to $2 runs every suite" "$ALL" "$(decide)"
}
shared_case fixture tests/a/fixtures/key.pem
shared_case library tests/lib/helper.sh
shared_case catalogue tests/mutation/catalog.txt
repo underlib; mkdir -p "$R/tests/lib"; echo y > "$R/tests/lib/helper.sh"; merge
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" \
	'if path.startswith("tests/") and not path.endswith(".test.sh"):' 'if False:'
check "without the rule for tests/ a helper skips every mapped suite" "tests/c/three.test.sh" "$(decide)"

shared_case dependencies scripts/quality/scope/suite-dependencies.txt
shared_case tool scripts/quality/scope/another-tool.sh
repo folder; mkdir -p "$R/scripts/quality/scope"; echo y > "$R/scripts/quality/scope/another-tool.sh"; merge
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" '"scripts/quality/scope/**",' '"scripts/quality/scope/ci-job-scope.sh",'
check "without the folder in the rule that tool skips every mapped suite" "tests/c/three.test.sh" "$(decide)"

shared_case ownsuite tests/quality/scope/new.test.sh
repo mechanism; mkdir -p "$R/tests/quality/scope"; echo y > "$R/tests/quality/scope/new.test.sh"; merge
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" '    "tests/quality/scope/**",
' ''
check "without the suites of the mechanism in the rule a suite of it skips every mapped suite" \
	"tests/c/three.test.sh" "$(decide)"

shared_case rootmodule yaml.py
shared_case rootpackage yaml/__init__.py
repo shadow; echo y > "$R/yaml.py"; merge
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" '    "*.py",
' ''
check "without the root modules in the rule one skips every mapped suite" "tests/c/three.test.sh" "$(decide)"
repo nested; mkdir -p "$R/scripts/c"; echo y > "$R/scripts/c/tool.py"; merge
check "a Python file that is not at the root is not an input of every suite" "tests/c/three.test.sh" "$(decide)"

# A suite is not one of those files: changing one runs it, and not the others.
repo onesuite; echo more >> "$R/tests/a/one.test.sh"; merge
check "a change to one suite runs it and the unmapped one, not every suite" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

# --- the decision fails open -----------------------------------------------------

repo rename; git -C "$R" mv scripts/b/y.sh scripts/b/renamed.sh; merge
check "a rename runs every suite" "$ALL" "$(decide)"

repo delete; git -C "$R" rm -q scripts/b/y.sh; merge
check "a deleted file counts as a change to its area" \
	"tests/b/two.test.sh tests/c/three.test.sh" "$(decide)"
# (scripts/b/** is in the entry of tests/b/two.test.sh)

repo ff; echo more >> "$R/scripts/a/x.sh"; git -C "$R" add -A; git -C "$R" commit -qm change
check "a checkout that is not the merge commit runs every suite" "$ALL" "$(decide)"

repo empty; git -C "$R" commit -q --allow-empty -m empty; git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff pr -m merge
check "an empty diff runs every suite" "$ALL" "$(decide)"

repo nomap; base_map -; echo more >> "$R/DOCS.md"; merge
check "a base commit without the map runs every suite" "$ALL" "$(decide)"

repo badmap; base_map $'tests/a/one.test.sh\n'; echo more >> "$R/DOCS.md"; merge
check "a map entry with no pattern runs every suite" "$ALL" "$(decide)"

repo dup; base_map $'tests/a/one.test.sh\n\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a suite listed twice in the map runs every suite" "$ALL" "$(decide)"

repo orphan; base_map $'\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a pattern before any suite runs every suite" "$ALL" "$(decide)"

# The pull request that moves the map into its folder: the base carries it at
# the path it had before, so the map is not where the resolver looks in the
# base. Reading the pull request's own copy there would let it choose its scope,
# and the one it brings says every suite can be skipped. Its text shares nothing
# with the old one, so git sees a deletion and an addition and not a rename,
# which would run everything for a different reason.
repo moved
git -C "$R" checkout -q main
git -C "$R" mv scripts/quality/scope/suite-scope.txt scripts/quality/suite-scope.txt
git -C "$R" commit -qm "the map before it moved"
git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
git -C "$R" rm -q scripts/quality/suite-scope.txt
printf 'tests/a/one.test.sh\n\tnothing/**\ntests/b/two.test.sh\n\tnothing/**\ntests/c/three.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"
echo more >> "$R/DOCS.md"; merge
check "a base that holds the map at the path it had before the move runs every suite" "$ALL" "$(decide)"

# A rename record is three fields, so two renames in the same pull request
# make the field count even and the parity check cannot notice them. The
# status of the record is what says "this is a rename": without it the second
# rename is read as a change of the first one, the path it came from is lost,
# and the suite that reads that path is skipped.
repo tworenames
git -C "$R" mv scripts/a/x.sh scripts/a/renamed.sh
git -C "$R" mv scripts/b/y.sh scripts/copy.sh
merge
check "a pull request with two renames runs every suite" "$ALL" "$(decide)"
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" \
	$'if status not in {b"A", b"M", b"D"} or not path_bytes:\n            return None' \
	$'if False:\n            return None'
check "without the rename status the suite of the second rename is skipped" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

# A git that cannot read the diff cannot establish the scope, and the
# resolver says so by running every suite. That fallback is the last line of
# defence, so it has to name every suite the caller asked for and not only
# the first one.
repo brokendiff; echo more >> "$R/DOCS.md"; merge
mkdir -p "$R/fakebin"
# shellcheck disable=SC2016 # the fake git reads these variables when it runs
printf '#!/usr/bin/env bash\n[ "$1" = diff ] && exit 42\nexec %s "$@"\n' "$(command -v git)" > "$R/fakebin/git"
chmod +x "$R/fakebin/git"
check "a git that fails the diff runs every suite" "$ALL" "$(decide "$R/fakebin")"
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" 'for name in sys.argv[2:]:' 'for name in sys.argv[2:3]:'
check "without the whole list in the fallback only the first suite would run" \
	"tests/a/one.test.sh" "$(decide "$R/fakebin")"

# --- what the resolver answers when it cannot answer -----------------------------
#
# A gate script that refuses nothing is what makes the mechanism safe: the
# decision it could not take is the whole list of suites, never a shorter one.

repo noargs
out="$( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh 2>/dev/null )"
check "the resolver without a mode prints no suite" "" "$out"
err="$( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh 2>&1 >/dev/null )"
check "and says that the scope could not be established" "1" "$(printf '%s' "$err" | grep -c 'Cannot establish the suite scope')"
check "and it does not refuse the job" "0" "$( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh >/dev/null 2>&1; echo $? )"

repo nomode
out="$( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh packages 2>/dev/null )"
check "the resolver in a mode it does not have prints no suite" "" "$out"

repo nogit
rm -rf "$R/.git"
out="$( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh suites $SUITES 2>/dev/null | tr '\n' ' ' | sed 's/ $//' )"
check "a tree that is not a repository runs every suite" "$ALL" "$out"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
