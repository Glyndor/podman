#!/usr/bin/env bash
#
# Print the entries of the mutation catalogue a pull request can affect, one id per
# line, `all` when every entry has to run, or nothing when none can.
#
# The whole sweep takes minutes, so a pull request does not pay for it when it cannot
# change the answer: whether a catalogued guard is still noticed changes only when the
# guarded file changes, or one of the suites the entry names, or what such a suite
# reads, or the entry itself. An entry is selected when:
#   - its file changed;
#   - its line of the catalogue is new or different from the base commit's;
#   - one of the suites it names changed;
#   - one of those suites names, by its file name, a script or workflow that changed
#     (a suite of the release workflow copies read-released.sh, and a change to that
#     script can stop the suite from reaching the guard it watches).
#
# Run the copy of this script taken from the BASE commit: a pull request that narrows
# the decision to hide its own guards gets the decision as the base makes it.
#
# Everything fails open. Any event but a pull request, a diff or a catalogue that
# cannot be read, an empty diff, and a change to the runner, to this script, to the
# workflow that runs them or to anything under tests/ that is not a suite or the
# catalogue (a helper the suites source, a fixture they read): each prints `all`.
# A wrong skip lets a dead guard merge; a wrong run costs minutes.
#
# What it cannot see: a suite that reads a file it does not name by its file name. The
# weekly sweep runs every entry and is what catches that.
#
# Environment: EVENT (the event name), BASE and HEAD (the commits of the pull request).
# Usage: EVENT=pull_request BASE=<sha> HEAD=<sha> mutation-scope.sh
set -euo pipefail
python3 -I - <<'PY'
import os
import re
import subprocess
import sys

# The catalogue is two files: the entries of an area live in the file that names
# it, and the two are one catalogue with one set of ids. A commit that has only
# the first of them is read with the first alone.
CATALOGS = ("tests/mutation/catalog.txt", "tests/mutation/catalog-tests.txt")
# Read by the coverage check, not by the sweep.
EXEMPTIONS = "tests/mutation/exemptions.txt"
GLOBAL_INPUTS = {
    "tests/mutation/run-mutations.sh",
    "scripts/quality/mutation-scope.sh",
    ".github/workflows/mutation.yml",
}
ID = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class Undecided(Exception):
    pass


def git(*args):
    return subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout.decode("utf-8")


def changed_paths(base, head):
    out = git("-c", "core.quotePath=false", "diff", "--no-renames", "--name-only", f"{base}...{head}", "--")
    paths = {line for line in out.split("\n") if line}
    if not paths:
        raise Undecided("the diff is empty")
    return paths


def catalogue(ref):
    entries = {}
    for name in CATALOGS:
        try:
            body = git("show", f"{ref}:{name}")
        except subprocess.CalledProcessError:
            # The first file is the catalogue; a commit that has only it is read
            # with it alone.
            if name == CATALOGS[0]:
                raise Undecided(f"the catalogue of {ref} cannot be read")
            continue
        for raw in body.split("\n"):
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            fields = raw.split("\t")
            if len(fields) != 5 or not ID.match(fields[0]) or fields[0] in entries:
                raise Undecided(f"a line of the catalogue of {ref} cannot be read")
            entries[fields[0]] = (raw, fields[1], [t for t in fields[4].split(",") if t])
    if not entries:
        raise Undecided(f"the catalogue of {ref} has no entries")
    return entries


def select():
    if os.environ.get("EVENT") != "pull_request":
        raise Undecided("not a pull request")
    base, head = os.environ.get("BASE", ""), os.environ.get("HEAD", "")
    if not base or not head:
        raise Undecided("no base or head commit")
    paths = changed_paths(base, head)
    if paths & GLOBAL_INPUTS:
        raise Undecided("the sweep itself changed")
    for path in paths - set(CATALOGS) - {EXEMPTIONS}:
        if path.startswith("tests/") and not path.endswith(".test.sh"):
            raise Undecided(f"{path} is read by suites and is not one")
    new, old = catalogue(head), catalogue(base)
    names = {os.path.basename(p) for p in paths if p.startswith(("scripts/", ".github/"))}
    texts = {}

    def reads_a_change(suite):
        if suite not in texts:
            try:
                texts[suite] = git("show", f"{head}:{suite}")
            except subprocess.CalledProcessError:
                texts[suite] = ""
        return any(name in texts[suite] for name in names)

    chosen = [ident for ident, (raw, path, tests) in new.items()
              if path in paths or old.get(ident, (None,))[0] != raw
              or any(t in paths or reads_a_change(t) for t in tests)]
    return chosen, len(new)


try:
    os.chdir(git("rev-parse", "--show-toplevel").strip())
    chosen, total = select()
except (Undecided, OSError, ValueError, UnicodeDecodeError, subprocess.CalledProcessError) as exc:
    print(f"Cannot narrow the mutation sweep; running every entry: {exc}", file=sys.stderr)
    print("all")
    sys.exit(0)
if len(chosen) == total:
    print("all")
else:
    for ident in chosen:
        print(ident)
PY
