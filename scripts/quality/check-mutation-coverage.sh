#!/usr/bin/env bash
# Fail when a refusal in a script or a workflow of this repository has neither an
# entry in the mutation catalogue nor a written exemption.
#
# The catalogue (tests/mutation/catalog.txt and tests/mutation/catalog-tests.txt)
# is what the mutation sweep runs, and the sweep only ever measures the guards it
# was told about. A guard nobody
# catalogued is invisible to the one instrument that would say whether a suite
# notices it gone, and before the catalogue existed, measuring by hand found about
# a dozen at a time that could be deleted with every suite green. This check closes the set
# from the other side: it reads the scripts, finds every refusal in them, and
# requires each one to be either mutated by an entry or exempted with a reason.
#
# The detector of refusals, which says what the shell and the Python of a script mean by
# one and where the statement that leads to it starts, is scripts/quality/mutation_refusals.py;
# this file holds what it finds to the catalogue and to the exemptions.
#
#
# An entry covers a refusal when the text it replaces lies on one of those
# lines. So does an exemption, which names a file, a text in it, and the reason
# the refusals that text reaches have no entry, separated by TAB in
# tests/mutation/exemptions.txt; a text of `*` exempts the whole file. An entry's
# text occurs once, because the runner refuses anything else; an exemption's
# text may occur more than once, for two refusals written alike, and every
# occurrence has to reach a refusal.
#
# An entry whose text is not in its file exactly once, or whose replacement is
# the text itself, is a failure whatever file it names: the sweep cannot apply
# it, and it would say so only after running every entry before it, which is
# minutes on a pull request and a week on the schedule.
#
# An exemption whose text is not in its file, one occurrence of which reaches no
# refusal, that has no reason, or that names a refusal an entry already covers
# is a failure: an exemption that outlived its premise keeps a hole open after
# the reason for it is gone.
#
#
# WHAT IS READ
#
# Every shell script under scripts/ (by extension, or by shebang for a file with
# none), every Python file under .github/scripts/, and the `run:` blocks of every
# workflow under .github/workflows/, .yml and .yaml: release.yml signs and
# publishes and no pull request runs it, and the others hold the gates of every
# pull request. Only the shell of a workflow is read; a description or a name that
# says `exit 1` is YAML, not a refusal. In a Python file, a call of `fail(` counts
# when the file defines `def fail`, as verify-sig.py and sign.py do. argparse's
# `parser.error(...)` exits 2 and is not read.
#
# Usage: check-mutation-coverage.sh [repo-root]   (default: the current directory)
set -euo pipefail
root="${1:-$PWD}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -I - "$root" "$here" <<'PY'
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[2])
from mutation_refusals import refusals, shell_of

root = sys.argv[1]
# The catalogue is two files: tests/mutation/catalog.txt and, when it is there,
# tests/mutation/catalog-tests.txt. The entries of an area live in the file that
# names it, and the two are one catalogue with one set of ids: an id in both of
# them is refused, as one repeated inside a file is. The second file is optional
# here: a catalogue that goes missing is caught by the rule below, which asks
# every refusal of the scripts for an entry.
CATALOGS = ("tests/mutation/catalog.txt", "tests/mutation/catalog-tests.txt")
EXEMPTIONS = "tests/mutation/exemptions.txt"
WATCHED_DIRS = ("scripts", ".github/scripts")
# The workflow that has to be there: the one that signs and publishes.
REQUIRED_FLOW = "release.yml"
WORKFLOWS = ".github/workflows"
SHEBANG = re.compile(r"^#!.*(/| )(sh|bash|dash)(\s|$)")
errors = []


def read(rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def is_script(rel):
    name = os.path.basename(rel)
    if name.endswith((".sh", ".bash", ".py")):
        return True
    if "." in name:
        return False
    try:
        first = read(rel).split("\n", 1)[0]
    except (OSError, UnicodeDecodeError):
        return False
    return bool(SHEBANG.match(first))


def watched():
    found = []
    for top in WATCHED_DIRS:
        for dirpath, dirnames, names in os.walk(os.path.join(root, top)):
            dirnames.sort()
            for name in sorted(names):
                rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
                if is_script(rel):
                    found.append(rel)
    try:
        names = sorted(os.listdir(os.path.join(root, WORKFLOWS)))
    except OSError:
        names = []
    flows = [f"{WORKFLOWS}/{n}" for n in names if n.endswith((".yml", ".yaml"))]
    if not flows:
        errors.append(f"{WORKFLOWS} holds no workflow, so its refusals cannot be read")
    if f"{WORKFLOWS}/{REQUIRED_FLOW}" not in flows:
        errors.append(f"{WORKFLOWS}/{REQUIRED_FLOW} is watched and does not exist")
    return found + flows


def is_workflow(rel):
    return rel.startswith(WORKFLOWS + "/")


def spans_of(text, needle):
    """Lines (first, last) of every occurrence of needle."""
    found, at = [], text.find(needle) if needle else -1
    while at >= 0:
        first = text.count("\n", 0, at)
        found.append((first, first + needle.count("\n")))
        at = text.find(needle, at + 1)
    return found


def span_of(text, needle):
    """Lines of the one occurrence of needle, or None."""
    found = spans_of(text, needle)
    return found[0] if len(found) == 1 else None


def entries():
    found = {}
    ids = {}
    for catalogue in CATALOGS:
        try:
            body = read(catalogue)
        except OSError as exc:
            # The first file is the catalogue; the second is read when it is
            # there, and a catalogue that is not is caught by the refusals it
            # left without an entry.
            if catalogue == CATALOGS[0]:
                errors.append(f"cannot read {catalogue}: {exc}")
            continue
        for raw in body.splitlines():
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            fields = raw.split("\t")
            if len(fields) != 5:
                errors.append(f"{catalogue}: a line does not hold five fields: {raw}")
                continue
            if fields[0] in ids:
                errors.append(f"{catalogue}: {fields[0]}: the id is already an entry of {ids[fields[0]]}, "
                              "so the sweep refuses the catalogue")
                continue
            ids[fields[0]] = catalogue
            found.setdefault(fields[1], []).append((fields[0], fields[2]))
            applies(catalogue, *fields[:4])
    return found


def applies(catalogue, ident, rel, old, new):
    """The runner's own conditions for applying an entry, checked without running it."""
    try:
        count = read(rel).count(old)
    except OSError:
        errors.append(f"{catalogue}: {ident}: {rel} cannot be read, so the sweep cannot apply the entry")
        return
    if count != 1:
        errors.append(f"{catalogue}: {ident}: its text is in {rel} {count} time(s), not once, "
                      "so the sweep cannot apply the entry")
    elif old == new:
        errors.append(f"{catalogue}: {ident}: it replaces its text with itself, so the sweep cannot apply the entry")


def exemptions():
    found = []
    if not os.path.isfile(os.path.join(root, EXEMPTIONS)):
        return found
    for number, raw in enumerate(read(EXEMPTIONS).splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 3 or not all(f.strip() for f in fields):
            errors.append(f"{EXEMPTIONS}:{number}: not `file<TAB>text<TAB>reason`: {raw}")
            continue
        found.append((number, fields[0], fields[1], fields[2]))
    return found


def overlaps(a, b):
    return a[0] <= b[1] and b[0] <= a[1]


files = watched()
catalogued = entries()
exempt = exemptions()
total = covered = exempted = 0
uncovered = []
used = set()
for rel in files:
    text = read(rel)
    lines = text.split("\n")
    if is_workflow(rel):
        lines = shell_of(lines)
    marks = []
    for ident, old in catalogued.get(rel, []):
        where = span_of(text, old)
        if where is not None:
            marks.append(where)
    whole = [e for e in exempt if e[1] == rel and e[2] == "*"]
    parts = [(e, spans_of(text, e[2])) for e in exempt if e[1] == rel and e[2] != "*"]
    for number, _, needle, _ in (e for e, where in parts if not where):
        errors.append(f"{EXEMPTIONS}:{number}: its text is not in {rel}: {needle}")
    if whole and catalogued.get(rel):
        errors.append(f"{EXEMPTIONS}:{whole[0][0]}: {rel} is exempt as a whole and has entries; exempt its refusals one by one")
    spans = refusals(rel, lines)
    for e, where in parts:
        for occurrence in where:
            if not any(overlaps(span, occurrence) for span in spans):
                errors.append(f"{EXEMPTIONS}:{e[0]}: its text at {rel}:{occurrence[0] + 1} reaches no refusal; delete it or narrow it")
    for span in spans:
        total += 1
        hit_entry = any(overlaps(span, m) for m in marks)
        hits = [e for e, where in parts if any(overlaps(span, w) for w in where)]
        for e in hits:
            used.add(e[0])
            if hit_entry:
                errors.append(f"{EXEMPTIONS}:{e[0]}: {rel}:{span[0] + 1} has an entry; delete the exemption")
        if whole:
            used.add(whole[0][0])
        if hit_entry:
            covered += 1
        elif hits or whole:
            exempted += 1
        else:
            uncovered.append((rel, span, lines[span[1]].strip()))
for number, rel, needle, _ in exempt:
    if rel not in files:
        errors.append(f"{EXEMPTIONS}:{number}: {rel} is not a script this check reads")
    elif number not in used and not any(f"{EXEMPTIONS}:{number}:" in e for e in errors):
        errors.append(f"{EXEMPTIONS}:{number}: it reaches no refusal in {rel}; delete it")
if not total:
    errors.append("no refusal found in any script, so this check would pass having looked at nothing")
for rel, (first, last), line in uncovered:
    errors.append(f"{rel}:{first + 1}-{last + 1}: a refusal with no entry in the catalogue "
                  f"and no exemption in {EXEMPTIONS}: {line}")
for message in errors:
    print(f"::error::{message}")
if errors:
    sys.exit(1)
print(f"{total} refusal(s) in {len(files)} script(s): {covered} catalogued, {exempted} exempt.")
PY
