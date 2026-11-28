#!/usr/bin/env bash
#
# The map in scripts/quality/scope/suite-scope.txt is a claim: "a change outside these
# paths cannot change this suite's verdict". A claim nobody checks rots in three
# ways, and each one is a way to skip a suite that should have run:
#
#   * a suite the job runs has no entry (it then always runs, which is safe
#     but means the map no longer says what it was written to say) -- or an entry
#     names a suite the job no longer runs;
#   * an entry cites a path that no file of the repository matches, so a rename
#     left a pattern that matches nothing and the suite is silently skipped for
#     the files that moved;
#   * an entry has no pattern at all;
#   * a suite reads a workflow its entry does not name. A suite that copies the
#     workflows of the repository, or opens one of them, is judging them, so a
#     change to a workflow that no pattern of its entry covers merges without
#     that suite running. The reads are the ones a suite spells from the root of
#     the repository (`$HERE/.github/workflows/<file>`, a glob of them or the
#     folder); a file it writes into a copy is not one.
#
# This reads the list of suites the job runs and the map from the working tree
# and requires them to agree, with planted copies of each defect so the checker
# can be seen to fail. The last case is the claim itself: a pull request that
# changes only the README runs the suites that read the README and none of the
# others.
#
# Requires: bash, python3.
# The fixtures are suites written as text, with `$HERE` meant to reach them
# unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCOPE_MAP="$HERE/scripts/quality/scope/suite-scope.txt"
DEPMAP="$HERE/scripts/quality/scope/suite-dependencies.txt"
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

# problems <repo-root>: prints one line per problem, nothing when the map is sound.
problems() {
	python3 -I - "$1" <<'PY'
import fnmatch, os, re, sys
root = sys.argv[1]


def walk(base):
    for dirpath, dirnames, names in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        for name in sorted(names):
            yield os.path.relpath(os.path.join(dirpath, name), base).replace(os.sep, "/")


# The suites the job runs: the ones the step of tests.yml finds under tests/.
suites = sorted("tests/" + p for p in walk(os.path.join(root, "tests")) if p.endswith(".test.sh"))
# The files of the repository, which is what a pattern has to match.
files = sorted(walk(root))

scope, current = {}, None
for raw in open(os.path.join(root, "scripts/quality/scope/suite-scope.txt")):
    line = raw.rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not line[:1].isspace():
        current = line.strip()
        if current in scope:
            print("listed twice: " + current)
        scope.setdefault(current, [])
    elif current is None:
        print("pattern before any suite: " + line.strip())
    else:
        scope[current].append(line.strip())


def _match(pattern_parts, path_parts):
    if not pattern_parts:
        return not path_parts
    head = pattern_parts[0]
    if head == "**":
        for cut in range(len(path_parts) + 1):
            if _match(pattern_parts[1:], path_parts[cut:]):
                return True
        return False
    if not path_parts:
        return False
    if not fnmatch.fnmatchcase(path_parts[0], head):
        return False
    return _match(pattern_parts[1:], path_parts[1:])


def covers(pattern, path):
    """The matcher of the resolver, so the map and the decision agree."""
    return _match(pattern.split("/"), path.split("/"))


def any_file(pattern):
    return any(covers(pattern, path) for path in files)


def folder_covers(pattern, path):
    """The folder of the pattern covers the path, as `dir/**` does."""
    return path.startswith(pattern[:-3] + "/")


reads = re.compile(r'\$\{?HERE\}?"?/(\.github/workflows(?:/[A-Za-z0-9_.*?-]+)?)')
for s, patterns in scope.items():
    if not os.path.isfile(os.path.join(root, s)):
        continue
    text = open(os.path.join(root, s), errors="replace").read()
    # A suite that reads "${1:-$HERE/.github/workflows}/file.yml" reads that file
    # and not the folder: the folder is only the default of the directory it
    # builds the name of.
    text = re.sub(r'\$\{1:-\$HERE/\.github/workflows\}(/[A-Za-z0-9_.*?-]+)',
                  r'$HERE/.github/workflows\1', text)
    for ref in sorted(set(r.rstrip(".") for r in reads.findall(text))):
        # The folder alone is every workflow in it.
        wanted = ref + "/*" if ref == ".github/workflows" else ref
        if any_file(wanted) and not any(covers(p, wanted) or folder_covers(p, wanted)
                                        for p in patterns):
            print("reads a workflow its entry does not name: %s (%s)" % (ref, s))
for s in suites:
    if s not in scope:
        print("no entry: " + s)
for s, patterns in scope.items():
    if s not in suites:
        print("not run by the workflow: " + s)
    if not patterns:
        print("no pattern: " + s)
    for p in patterns:
        if not any_file(p):
            print("cites a path that no file matches: %s (%s)" % (p, s))
PY
}

# A tiny repository that has the list of suites and the map, so a defect can be
# planted. The tree stands for the one of the repository: the map is read from
# scripts/quality/scope/, and the suites are the ones under tests/.
tree() {
	local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/scripts/quality/scope" "$d/scripts/a" "$d/tests/a"
	printf 'x\n' > "$d/scripts/a/x.sh"
	printf 'tests/a/one.test.sh\n\tscripts/a/**\n\ntests/a/two.test.sh\n\ttests/a/two.test.sh\n' > "$d/scripts/quality/scope/suite-scope.txt"
	printf 'x\n' > "$d/tests/a/one.test.sh"; printf 'x\n' > "$d/tests/a/two.test.sh"
	echo "$d"
}

D="$(tree sound)"; check "control: a sound map reports nothing" "" "$(problems "$D")"

D="$(tree missing)"; printf '\ntests/a/three.test.sh\n\tscripts/a/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "an entry for a suite the job does not run is reported" "not run by the workflow: tests/a/three.test.sh" \
	"$(problems "$D" | grep '^not run by the workflow')"

D="$(tree noentry)"; printf 'x\n' > "$D/tests/a/three.test.sh"
check "a suite the job runs with no entry is reported" "no entry: tests/a/three.test.sh" "$(problems "$D")"

D="$(tree moved)"; rm -rf "$D/scripts/a"
check "a pattern whose directory was renamed away is reported" \
	"cites a path that no file matches: scripts/a/** (tests/a/one.test.sh)" "$(problems "$D")"

D="$(tree file)"; rm "$D/tests/a/two.test.sh"
check "an exact file entry whose file is gone is reported" \
	"cites a path that no file matches: tests/a/two.test.sh (tests/a/two.test.sh)" \
	"$(problems "$D" | grep '^cites a path')"

D="$(tree empty)"; printf 'tests/a/one.test.sh\n' > "$D/scripts/quality/scope/suite-scope.txt"
check "an entry with no pattern is reported" "no pattern: tests/a/one.test.sh" "$(problems "$D" | grep '^no pattern')"

D="$(tree twice)"; printf '\ntests/a/one.test.sh\n\tscripts/a/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "a suite listed twice is reported" "listed twice: tests/a/one.test.sh" "$(problems "$D")"

D="$(tree orphan)"; printf '\tscripts/a/**\n' > "$D/orphan"; cat "$D/orphan" "$D/scripts/quality/scope/suite-scope.txt" > "$D/map"; mv "$D/map" "$D/scripts/quality/scope/suite-scope.txt"
check "a pattern before any suite is reported" "pattern before any suite: scripts/a/**" "$(problems "$D" | grep '^pattern before')"

# The folder alone says the suite reads some workflow, and an entry that names
# one is the entry of a suite that reads the ones it names.
# --- a suite that reads the workflows of the repository --------------------
reader() { # $1=tree name, $2=the line the suite runs
	local d; d="$(tree "$1")"
	printf '#!/usr/bin/env bash\n%s\n' "$2" > "$d/tests/a/two.test.sh"
	printf '%s' "$d"
}

D="$(reader glob 'cp "$HERE"/.github/workflows/*.yml "$tmp"')"
mkdir -p "$D/.github/workflows"; printf 'name: x\n' > "$D/.github/workflows/one.yml"
check "a suite that copies every workflow, with an entry that names none, is reported" \
	"reads a workflow its entry does not name: .github/workflows/*.yml (tests/a/two.test.sh)" "$(problems "$D")"
printf '\t.github/workflows/one.yml\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "and naming one workflow does not cover a glob of all of them" \
	"reads a workflow its entry does not name: .github/workflows/*.yml (tests/a/two.test.sh)" "$(problems "$D")"
printf '\t.github/workflows/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "and the folder pattern covers it" "" "$(problems "$D")"
D="$(reader glob2 'cp "$HERE"/.github/workflows/*.yml "$tmp"')"
mkdir -p "$D/.github/workflows"; printf 'name: x\n' > "$D/.github/workflows/one.yml"
printf '\tscripts/a/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "a folder pattern of another folder does not cover the workflows" \
	"reads a workflow its entry does not name: .github/workflows/*.yml (tests/a/two.test.sh)" "$(problems "$D")"

D="$(reader file 'cat "$HERE/.github/workflows/one.yml"')"
mkdir -p "$D/.github/workflows"; printf 'name: x\n' > "$D/.github/workflows/one.yml"; printf 'name: y\n' > "$D/.github/workflows/two.yml"
check "a suite that opens one workflow, with an entry that names another, is reported" \
	"reads a workflow its entry does not name: .github/workflows/one.yml (tests/a/two.test.sh)" "$(problems "$D")"
printf '\t.github/workflows/one.yml\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "and naming that workflow covers it" "" "$(problems "$D")"

D="$(reader written 'cp x "$d/.github/workflows/one.yml"')"
mkdir -p "$D/.github/workflows"; printf 'name: x\n' > "$D/.github/workflows/one.yml"
check "a workflow the suite writes into a copy is not a read" "" "$(problems "$D")"

check "the real map agrees with the real tree and the real list of suites" "" "$(problems "$HERE")"

# --- the dependency map ------------------------------------------------------------
#
# The file that says what each suite needs beyond the runner. A suite that is
# not in it gets the whole install, which is safe, and a suite in it that does
# not exist is a line that says nothing.

deps_problems() {
	python3 -I - "$1" "$2" <<'PY'
import os, sys
root, depmap = sys.argv[1:3]
suites = set()
for dirpath, dirnames, names in os.walk(os.path.join(root, "tests")):
    dirnames[:] = sorted(d for d in dirnames if d != ".git")
    for name in names:
        if name.endswith(".test.sh"):
            suites.add("tests/" + os.path.relpath(os.path.join(dirpath, name), os.path.join(root, "tests")).replace(os.sep, "/"))
TOOLS = {"-", "mldsa-wheel"}
seen = set()
for number, raw in enumerate(open(depmap, encoding="utf-8").read().splitlines(), 1):
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    fields = raw.split()
    if len(fields) != 2:
        print("malformed entry: " + raw)
        continue
    suite, tool = fields
    if suite in seen:
        print("listed twice: " + suite)
    seen.add(suite)
    if suite not in suites:
        print("not a suite of the repository: " + suite)
    if tool not in TOOLS:
        print("an unknown tool: %s (%s)" % (tool, suite))
for suite in sorted(suites - seen):
    print("no entry: " + suite)
PY
}

check "the real dependency map names every suite and a known tool" "" "$(deps_problems "$HERE" "$DEPMAP")"

D="$(tree deps)"; printf 'tests/a/three.test.sh -\ntests/a/one.test.sh -\ntests/a/two.test.sh -\n' > "$D/deps.txt"
check "a dependency entry for a suite that does not exist is reported" \
	"not a suite of the repository: tests/a/three.test.sh" \
	"$(deps_problems "$D" "$D/deps.txt" | grep '^not a suite')"

D="$(tree deps)"; printf 'tests/a/two.test.sh -\n' > "$D/deps.txt"
check "a suite the repository runs with no dependency entry is reported" \
	"no entry: tests/a/one.test.sh" "$(deps_problems "$D" "$D/deps.txt" | grep '^no entry')"

D="$(tree deps)"; printf 'tests/a/one.test.sh -\ntests/a/two.test.sh -\ntests/a/one.test.sh -\n' > "$D/deps.txt"
check "a suite listed twice in the dependency map is reported" \
	"listed twice: tests/a/one.test.sh" "$(deps_problems "$D" "$D/deps.txt" | grep '^listed twice')"

# --- the claim itself: a pull request that changes only the README ----------------
#
# The map is a claim about what a change can break. A change to the README can
# only break the suites that read it, so those run and the others do not.

real_repo() { # <name>: a repository carrying the resolver and the map this
	# repository ships, so the decision is taken with the real map.
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/docs" "$R/.github/workflows"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$HERE/scripts/quality/scope/ci-job-scope.sh" "$R/scripts/quality/scope/ci-job-scope.sh"
	cp "$SCOPE_MAP" "$R/scripts/quality/scope/suite-scope.txt"
	printf 'readme\n' > "$R/README.md"; printf 'contributing\n' > "$R/CONTRIBUTING.md"
	printf 'docs\n' > "$R/docs/notes.md"; printf 'x\n' > "$R/scripts/quality/hygiene.sh"
	printf 'x\n' > "$R/.github/workflows/tests.yml"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# real_merge: commit the pending changes and build the merge commit GitHub builds.
real_merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# real_decide <suite>...: the suites the resolver keeps, one per line.
real_decide() {
	( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh suites "$@" 2>/dev/null )
}
# has: 1 when the suite is among the ones the decision kept.
#
# The decision is read with a here-string rather than a pipeline, and that is
# not a style choice. `grep -q` stops at the first match and closes the pipe,
# so the writer on the left dies of SIGPIPE; with `pipefail` on, the pipeline
# then reports 141 even though grep DID match, and this helper answers "the
# suite is not among them" about a suite that is. The here-string has no
# pipeline and no writer to kill, so the answer is grep's alone.
has() { # <suite> <decision>
	if grep -qxF -- "$1" <<< "$2"; then echo 1; else echo 0; fi
}
# lacks: 1 when the suite is not among them.
lacks() { # <suite> <decision>
	if grep -qxF -- "$1" <<< "$2"; then echo 0; else echo 1; fi
}

# The suites of the repository, which is what the decision is taken over.
ALL_SUITES="$(cd "$HERE" && find tests -name '*.test.sh' | LC_ALL=C sort)"

real_repo readme; echo more >> "$R/README.md"; real_merge
got="$(real_decide $ALL_SUITES)"
check "a README-only change runs the suite that reads the README" "1" \
	"$(has tests/docs/verify-second-signature.test.sh "$got")"
check "a README-only change runs the suites that walk the whole tree" "11" \
	"$(has tests/quality/check-folder-size.test.sh "$got")$(has tests/quality/scope/suite-scope-map.test.sh "$got")"
check "a README-only change does not run the suite that reads CONTRIBUTING" "1" \
	"$(lacks tests/docs/contributing-workflows.test.sh "$got")"
check "a README-only change does not run the secret scan suite" "1" \
	"$(lacks tests/quality/check-secrets.test.sh "$got")"
check "a README-only change does not run a suite that reads neither" "1" \
	"$(lacks tests/ci/decide-build.test.sh "$got")"
check "a README-only change does not run the suite of the workflows" "1" \
	"$(lacks tests/workflows/policy/workflow-policy.test.sh "$got")"
check "and it runs fewer suites than the repository has" "1" \
	"$([ "$(printf '%s\n' "$got" | grep -c .)" -lt "$(printf '%s\n' "$ALL_SUITES" | grep -c .)" ] && echo 1 || echo 0)"

real_repo contributing; echo more >> "$R/CONTRIBUTING.md"; real_merge
got="$(real_decide $ALL_SUITES)"
check "a CONTRIBUTING-only change runs the suite that reads CONTRIBUTING" "1" \
	"$(has tests/docs/contributing-workflows.test.sh "$got")"
check "a CONTRIBUTING-only change does not run the secret scan suite" "1" \
	"$(lacks tests/quality/check-secrets.test.sh "$got")"

real_repo script; echo more >> "$R/scripts/quality/hygiene.sh"; real_merge
got="$(real_decide $ALL_SUITES)"
check "a change to a script of scripts/quality runs the suites that read it" "1" \
	"$(has tests/quality/check-secrets.test.sh "$got")"
check "and the suites that walk every script" "1" \
	"$(has tests/quality/check-test-coverage.test.sh "$got")"
check "and none of the suites that read neither" "1" \
	"$(lacks tests/docs/contributing-workflows.test.sh "$got")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
