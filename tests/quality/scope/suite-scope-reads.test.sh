#!/usr/bin/env bash
#
# An entry of scripts/quality/scope/suite-scope.txt says which paths can change a
# suite's verdict. This reads the text of every suite with an entry, finds the
# files of the repository it reaches, and requires the entry to cover each one:
#
#   * a path spelled from the root of the repository to a script, a key or a
#     library of tests/lib (`scripts/...`, `.github/scripts/...`,
#     `keyring/...`, `tests/lib/...`);
#   * a path built on the folder of the file that names it (`$HERE/...`,
#     `$here/../...`, `$(dirname "$0")/...`);
#   * a folder `find` walks;
#   * what the scripts and the libraries of tests/lib reached that way reach in
#     turn, by the same two forms of a path;
#   * for the suite of the mutation coverage check, every file the catalogue
#     names, which that check reads.
#
# It reads text, so it does not see: a path put together at run time, a step of a
# workflow run with the repository as its workspace, what `git ls-files` or
# `git archive` read, a copy of a whole folder under another variable, or a path
# a library takes as any argument but its first. Those entries were written from
# a trace of what each suite opens, and the weekly full run of mutation.yml is
# what notices an entry that no longer matches. The workflows are left out: a
# change to one runs every suite.
#
# Requires: bash, python3.
# The fixtures are suites written as text, with the variables meant to reach them
# unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# problems <repo-root>: prints one line per file a suite reaches and its entry
# does not cover.
problems() {
	python3 -I - "$1" <<'PY'
import fnmatch, glob, os, re, sys
root = sys.argv[1]

# A path spelled from the root, not one that hangs from a variable or a folder.
LITERAL = re.compile(r"(?<![\w./$}-])(?:\./)?((?:scripts|keyring|tests/lib|\.github/scripts)(?:/[\w.*?-]+)+)")
# `name="$(cd "$(dirname "$0")/.." && pwd)"`, also as the default of `${1:-...}`.
ASSIGNED = re.compile(r'\b([A-Za-z_]\w*)="?(?:\$\{\w+:-)?\$\(\s*cd "\$\(dirname "\$(?:0|\{BASH_SOURCE\[0\]\})"\)'
                      r'((?:/\.\.)*)"\s*&&\s*pwd\s*\)')
# `other="$(cd "$name/.." && pwd)"`: another folder, built on one of those.
DERIVED = re.compile(r'\b([A-Za-z_]\w*)="?\$\(\s*cd "\$\{?([A-Za-z_]\w*)\}?((?:/\.\.)+)"\s*&&\s*pwd\s*\)')
VARIABLE = re.compile(r'\$\{?([A-Za-z_]\w*|1)\}?"?/([\w.*?/-]+)')
INLINE = re.compile(r'\$\(dirname "\$(?:0|\{BASH_SOURCE\[0\]\})"\)((?:/[\w.*?-]+)+)')
WALK = re.compile(r'\bfind "?(?:\$\{?(?:HERE|here|root|ROOT)\}?"?/)?(scripts|keyring|docs|tests)(?=[\s"\')])')
# The check this suite runs on the repository reads every file the catalogue names.
CATALOGUE_READER = "tests/quality/check-mutation-coverage.test.sh"
CATALOGUE = "tests/mutation/catalog.txt"


def reached(rel, kind):
    """path -> True when the file uses it (and so may run it), False when it only
    spells it. A script that is not a suite or a library is read for the paths it
    uses alone: the ones it spells are messages and patterns."""
    with open(os.path.join(root, rel), errors="replace") as fh:
        text = fh.read()
    folder = os.path.dirname(rel)
    # The first definition is the file's own: a later one is text it writes.
    bases = {}
    for name, ups in ASSIGNED.findall(text):
        bases.setdefault(name, os.path.join(folder, "." + ups))
    for name, base, ups in DERIVED.findall(text):
        if base in bases:
            bases.setdefault(name, os.path.normpath(os.path.join(bases[base], "." + ups)))
    if kind != "suite":
        bases.setdefault("HERE", "")
    if kind == "library":
        bases["1"] = ""
    found = {}
    for line in text.split("\n"):
        if line.lstrip().startswith("#"):
            continue
        # Naming a folder reads nothing in it: what is read is built on it later.
        line = DERIVED.sub("", ASSIGNED.sub("", line))
        if kind != "script":
            for path in LITERAL.findall(line) + WALK.findall(line):
                found.setdefault(path, False)
        for name, tail in VARIABLE.findall(line):
            if name in bases:
                found[os.path.join(bases[name], tail)] = True
        for tail in INLINE.findall(line):
            found[os.path.join(folder, "." + tail)] = True
    out = {}
    for path, used in found.items():
        # A period that ends a sentence goes; the dots of `..` stay.
        if path.endswith(".") and not path.endswith(("/.", "..")):
            path = path[:-1]
        path = os.path.normpath(path)
        if path == "." or path.startswith("..") or (path + "/").startswith(".github/workflows/"):
            continue
        if any(c in path for c in "*?"):
            hits = glob.glob(os.path.join(glob.escape(root), path), include_hidden=True)
            names = [os.path.relpath(hit, root) for hit in hits]
        else:
            names = [path] if os.path.exists(os.path.join(root, path)) else []
        for name in names:
            out[name] = out.get(name, False) or used
    return out


def reads(suite):
    """path -> the file that reaches it, for everything the suite reaches."""
    seen, queue, done = {}, [(suite, "suite")], set()
    while queue:
        rel, kind = queue.pop(0)
        if rel in done:
            continue
        done.add(rel)
        for path, used in sorted(reached(rel, kind).items()):
            seen.setdefault(path, rel)
            if (used and path.endswith((".sh", ".py")) and not path.endswith(".test.sh")
                    and path.startswith(("scripts/", ".github/scripts/", "tests/"))
                    and os.path.isfile(os.path.join(root, path))):
                queue.append((path, "library" if path.startswith("tests/lib/") else "script"))
    catalogue = os.path.join(root, CATALOGUE)
    if suite == CATALOGUE_READER and os.path.isfile(catalogue):
        for line in open(catalogue, encoding="utf-8"):
            fields = line.split("\t")
            if len(fields) == 5 and not line.startswith("#") and not fields[1].startswith(".github/workflows/"):
                seen.setdefault(fields[1], CATALOGUE)
    return seen


def _match(pattern_parts, path_parts):
    if not pattern_parts:
        return not path_parts
    head = pattern_parts[0]
    if head == "**":
        return any(_match(pattern_parts[1:], path_parts[cut:]) for cut in range(len(path_parts) + 1))
    if not path_parts or not fnmatch.fnmatchcase(path_parts[0], head):
        return False
    return _match(pattern_parts[1:], path_parts[1:])


def covered(patterns, path):
    """A folder is covered when a file that arrives anywhere under it is: any
    file, and under tests/ a new suite too."""
    probes = [path]
    if os.path.isdir(os.path.join(root, path)):
        probes = [path + "/zz-new/zz-probe"]
        if (path + "/").startswith("tests/"):
            probes.append(path + "/zz-new/zz-probe.test.sh")
    return all(any(_match(p.split("/"), probe.split("/")) for p in patterns) for probe in probes)


scope, current = {}, None
with open(os.path.join(root, "scripts/quality/scope/suite-scope.txt")) as fh:
    for raw in fh:
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[:1].isspace():
            current = line
            scope.setdefault(current, [])
        elif current is not None:
            scope[current].append(line.strip())
for suite, patterns in sorted(scope.items()):
    if not os.path.isfile(os.path.join(root, suite)):
        continue
    for path, via in sorted(reads(suite).items()):
        if path != suite and not covered(patterns, path):
            through = "" if via == suite else ", through " + via
            print("read not covered: %s (%s%s)" % (path, suite, through))
PY
}

# --- planted trees ------------------------------------------------------------

# tree <name> <line of the suite>: a repository with one suite, whose entry
# covers scripts/a/ alone.
tree() {
	D="$WORK/$1"; rm -rf "$D"
	mkdir -p "$D/scripts/quality/scope" "$D/scripts/a" "$D/scripts/b" "$D/keyring" "$D/.github/scripts" "$D/tests/a" "$D/tests/lib"
	printf 'x\n' > "$D/scripts/a/x.sh"; printf 'x\n' > "$D/scripts/b/y.sh"; printf 'x\n' > "$D/keyring/k"
	printf 'x\n' > "$D/.github/scripts/sign.py"; printf 'x\n' > "$D/tests/lib/helper.sh"
	printf 'tests/a/one.test.sh\n\tscripts/a/**\n' > "$D/scripts/quality/scope/suite-scope.txt"
	printf '#!/usr/bin/env bash\n%s\n' "$2" > "$D/tests/a/one.test.sh"
}
cover() { printf '\t%s\n' "$1" >> "$D/scripts/quality/scope/suite-scope.txt"; }
uncovered() { echo "read not covered: $1 (tests/a/one.test.sh${2:+, through $2})"; }

# reports <description> <line of the suite> <path>: the line reaches the path,
# the entry does not cover it, and covering it ends the report.
reports() {
	tree case "$2"
	check "$1 is reported" "$(uncovered "$3")" "$(problems "$D")"
	cover "$3"
	check "and covering it ends the report" "" "$(problems "$D")"
}
# silent <description> <line of the suite>: nothing to report.
silent() {
	tree case "$2"
	check "$1" "" "$(problems "$D")"
}

silent "control: a suite that reaches what its entry covers reports nothing" \
	'HERE="$(cd "$(dirname "$0")/../.." && pwd)"; bash "$HERE/scripts/a/x.sh"'
reports "a path built on the root" \
	'HERE="$(cd "$(dirname "$0")/../.." && pwd)"; bash "$HERE/scripts/b/y.sh"' scripts/b/y.sh
reports "a path built on the folder of the suite" \
	'here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cat "$here/../../keyring/k"' keyring/k
reports "a path built on dirname in place" 'cat "$(dirname "$0")/../../keyring/k"' keyring/k
reports "a script of .github/scripts spelled from the root" 'python3 .github/scripts/sign.py' .github/scripts/sign.py
reports "a script spelled from the root" 'bash scripts/b/y.sh' scripts/b/y.sh
reports "a key spelled from the root" 'cat ./keyring/k' keyring/k
reports "a library of tests/lib" \
	'HERE="$(cd "$(dirname "$0")/../.." && pwd)"; . "$HERE/tests/lib/helper.sh"' tests/lib/helper.sh

silent "a path in a comment is not a read" '# bash scripts/b/y.sh'
silent "a path under the folder of a fixture is not a read" 'cp x "$R/scripts/b/y.sh"'
silent "a path no file of the repository has is not a read" 'cat keyring/no-such-key'

tree through 'HERE="$(cd "$(dirname "$0")/../.." && pwd)"; bash "$HERE/scripts/a/x.sh"'
printf 'here="$(cd "$(dirname "$0")" && pwd)"\nbash "$here/../b/y.sh"\n' > "$D/scripts/a/x.sh"
check "what a script reaches is a read of the suite that runs it" \
	"$(uncovered scripts/b/y.sh scripts/a/x.sh)" "$(problems "$D")"
printf 'echo "run scripts/b/y.sh by hand"\n' > "$D/scripts/a/x.sh"
check "a path a script only spells is a message, not a read" "" "$(problems "$D")"

tree derived 'HERE="$(cd "$(dirname "$0")/../.." && pwd)"; bash "$HERE/scripts/a/x.sh"'
printf 'here="$(cd "$(dirname "$0")" && pwd)"\nscripts="$(cd "$here/.." && pwd)"\nbash "$scripts/b/y.sh"\n' > "$D/scripts/a/x.sh"
check "a path built on a folder that is built on another is followed, and naming the folder is not a read of it" \
	"$(uncovered scripts/b/y.sh scripts/a/x.sh)" "$(problems "$D")"

tree library 'HERE="$(cd "$(dirname "$0")/../.." && pwd)"; . "$HERE/tests/lib/helper.sh"; copy_key "$HERE"'
printf 'copy_key() { cp "$1/keyring/k" "$2"; }\n' > "$D/tests/lib/helper.sh"
cover 'tests/lib/**'
check "what a library reads from the root it is given is a read of the suite" \
	"$(uncovered keyring/k tests/lib/helper.sh)" "$(problems "$D")"

tree dots 'HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE/../.."; echo "see scripts/a/x.sh."'
check "a path that climbs back to the root is not a read of the folder above the suite, and a final period is not part of a path" \
	"" "$(problems "$D")"

tree walk 'cd "$HERE" && find tests -name "*.test.sh"'
check "a folder find walks is reported" "$(uncovered tests)" "$(problems "$D")"
cover 'tests/*/*.zz'; cover 'tests/*'
check "and a pattern a new suite would not match does not cover it" "$(uncovered tests)" "$(problems "$D")"
cover 'tests/**'
check "and the whole folder does" "" "$(problems "$D")"

tree catalogue 'true'
mv "$D/tests/a/one.test.sh" "$D/tests/a/two.test.sh"
mkdir -p "$D/tests/quality" "$D/tests/mutation"; printf 'true\n' > "$D/tests/quality/check-mutation-coverage.test.sh"
printf 'tests/quality/check-mutation-coverage.test.sh\n\tscripts/a/**\n' > "$D/scripts/quality/scope/suite-scope.txt"
printf 'id\t.github/scripts/sign.py\told\tnew\ttests/a/two.test.sh\n' > "$D/tests/mutation/catalog.txt"
check "a file the catalogue names is a read of the suite of the coverage check" \
	"read not covered: .github/scripts/sign.py (tests/quality/check-mutation-coverage.test.sh, through tests/mutation/catalog.txt)" \
	"$(problems "$D")"

# --- the map of this repository ------------------------------------------------

check "every file a suite of this repository reaches is covered by its entry" "" "$(problems "$HERE")"

# The same map with one line taken out of one entry has to be reported, for the
# reads a suite makes in each of the ways above.
real="$WORK/real"
mkdir -p "$real"
cp -r "$HERE/scripts" "$HERE/tests" "$HERE/keyring" "$HERE/docs" "$HERE/.github" "$real/"
cp "$HERE"/*.md "$real/"
# without <suite> <pattern>: the map of the repository without that line of that
# entry; stops loudly when the entry does not have it.
without() {
	python3 -I - "$HERE/scripts/quality/scope/suite-scope.txt" "$real/scripts/quality/scope/suite-scope.txt" "$1" "$2" <<'PY'
import sys
source, target, suite, pattern = sys.argv[1:5]
out, current, found = [], None, 0
for line in open(source).read().split("\n"):
    if line and not line[:1].isspace() and not line.startswith("#"):
        current = line
    if current == suite and line.strip() == pattern:
        found += 1
        continue
    out.append(line)
if found != 1:
    sys.exit("the entry of %s holds %s %d times" % (suite, pattern, found))
open(target, "w").write("\n".join(out))
PY
}
# missed <suite> <pattern> <path>: 1 when the report names the path for the suite.
missed() {
	without "$1" "$2" || { echo "no-such-line"; return; }
	if problems "$real" | grep -qF -- "read not covered: $3 ($1"; then echo 1; else echo 0; fi
}
check "without scripts/upstream the suite of the delivery lag is reported" "1" \
	"$(missed tests/monitoring/delivery-lag.test.sh 'scripts/upstream/**' scripts/upstream/plan-release.sh)"
check "without scripts/build the suite of the payload is reported" "1" \
	"$(missed tests/package/build-payload.test.sh 'scripts/build/**' scripts/build/install-common-config.sh)"
check "without .github/scripts/release the suite of the plan is reported" "1" \
	"$(missed tests/upstream/plan-release.test.sh '.github/scripts/release/**' .github/scripts/release/sign.py)"
check "without tests/lib the suite of the mutation runner is reported" "1" \
	"$(missed tests/mutation/run-mutations.test.sh 'tests/lib/**' tests/lib/mutation-syntax.sh)"
check "without tests the suite of the scope step is reported" "1" \
	"$(missed tests/quality/scope/ci-job-scope-suites.test.sh 'tests/**' tests)"
cp "$HERE/scripts/quality/scope/suite-scope.txt" "$real/scripts/quality/scope/suite-scope.txt"
check "and with every line back the copy reports nothing" "" "$(problems "$real")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
