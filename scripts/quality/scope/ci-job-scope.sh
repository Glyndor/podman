#!/usr/bin/env bash
# Print the suites a pull request can affect, one per line. The decision is
# taken with the map in scripts/quality/scope/suite-scope.txt as they are in the
# BASE commit, never as the pull request ships them, so a pull request that
# narrows the map to hide its own suite gets the full set instead. That is the
# rule for a gate script: a gate script is read from the base commit, never
# from the checkout of the pull request it is judging.
#
# Everything fails open. A diff that cannot be read, a rename, a copy, a type
# change, a map that cannot be parsed, a suite the map does not know: all of
# them run every suite. A wrong skip lets a change merge untested; a wrong run
# costs seconds, and the asymmetry decides every borderline case in favour of
# running.
#
# Only the `suites` mode is here. The other modes of the resolver of the rpm
# and the pacman repositories -- the one that narrows an APT install to the
# packages the selected suites need, and the one that answers for a suite that
# has a job of its own -- answer questions this repository does not ask: its
# runner installs nothing by package name, and every suite it runs runs in the
# same job.
#
# Usage: ci-job-scope.sh suites <suite> [<suite> ...]
set -euo pipefail
python3 -I - "$@" <<'PY'
import fnmatch
import os
import subprocess
import sys


# The map that says which paths can change each suite's verdict.
#
# It is read from the BASE commit, never from the checkout of the pull request:
# a pull request that narrows the map or rewrites this script to narrow its
# own scope gets the full set instead, because the base copy is what decides.
MAP = "scripts/quality/scope/suite-scope.txt"

# What is an input of every suite, by rule rather than by an entry per suite:
# a change to any of it changes WHAT RUNS, WHO RUNS IT or what every suite
# stands on, so it runs everything. Keeping the rule here means a suite added to
# the map later cannot forget it.
#
#   * this folder (the resolver, the map and the tools) and the suites of the
#     mechanism itself;
#   * the workflows, whose steps run the suites;
#   * what Python can import from the root of the repository: the suites that
#     run `python3 -` from there look in it first, so a file there can stand in
#     for a module any of them loads. A module or a compiled module at the
#     root, and the `__init__` of any kind that makes a root folder a package.
#
# A file under tests/ that is not a suite (a helper the suites source, a fixture
# they read, the mutation catalogue and its runner) is one too, and so is any
# file or folder that is new at the root under a name Python can import: see
# shared().
GLOBAL_INPUTS = (
    "scripts/quality/scope/**",
    "tests/quality/scope/**",
    ".github/workflows/**",
    "*.py",
    "*.pyc",
    "*.pyd",
    "*.so",
    "*/__init__.*",
)


def git(*args):
    return subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


def merge_commit():
    """True when HEAD is a merge commit with two parents.

    The scope is decided by comparing HEAD^1 (the base) with HEAD. That is
    the whole pull request only when the checkout is the merge commit GitHub
    builds for refs/pull/N/merge, whose first parent is the base branch tip.
    On a checkout of the branch head instead, HEAD^1 is the previous commit
    of the branch, the comparison covers only the last commit, and suites a
    pull request can affect are skipped. Reading the parent count from the
    commit object answers the same in a shallow clone, where resolving a
    parent NAME does not.
    """
    try:
        body = git("cat-file", "-p", "HEAD")
    except (OSError, subprocess.CalledProcessError):
        return False
    parents = sum(1 for line in body.splitlines() if line.startswith(b"parent "))
    return parents == 2


def changed_paths():
    """The paths this pull request changes.

    None when that cannot be established: an unreadable diff, a rename, a
    copy, a type change or an unknown record. A rename in particular is two
    paths, and both count, so moving a script cannot hide it."""
    if not merge_commit():
        # The checkout is not the merge commit, so HEAD^1..HEAD is not the
        # pull request and the scope cannot be established from it.
        return None
    return name_status_paths(
        git("diff", "--name-status", "-z", "--find-renames", "HEAD^1", "HEAD", "--"))


def name_status_paths(raw):
    """The paths of a `git diff --name-status -z` listing, or None when it is
    empty, malformed, or holds a record that is not a plain add, modify or
    delete: renames/copies, type changes and unknown records are not a safe
    skip."""
    if not raw or not raw.endswith(b"\0"):
        return None
    fields = raw[:-1].split(b"\0")
    if len(fields) % 2:
        return None
    paths = []
    for status, path_bytes in zip(fields[::2], fields[1::2]):
        if status not in {b"A", b"M", b"D"} or not path_bytes:
            return None
        paths.append(os.fsdecode(path_bytes))
    return paths


def parse_map(text):
    """Suite path -> the patterns that can change its verdict.

    None when the map cannot be read: a suite listed twice, a pattern before
    any suite, an entry with no pattern at all. An entry with no pattern would
    never run, and a mistake that hides a suite is the one that must not
    survive, so the whole set runs instead."""
    scope = {}
    current = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        if not line[:1].isspace():
            current = line.strip()
            if current in scope:
                return None
            scope[current] = []
            continue
        if current is None:
            return None
        scope[current].append(line.strip())
    if not scope:
        return None
    for patterns in scope.values():
        if not patterns:
            return None
    return scope


def _match(pattern_parts, path_parts):
    if not pattern_parts:
        return not path_parts
    head = pattern_parts[0]
    if head == "**":
        # `**` covers any number of segments, including none.
        for cut in range(len(path_parts) + 1):
            if _match(pattern_parts[1:], path_parts[cut:]):
                return True
        return False
    if not path_parts:
        return False
    if not fnmatch.fnmatchcase(path_parts[0], head):
        return False
    return _match(pattern_parts[1:], path_parts[1:])


def matches(pattern, path):
    """True when the pattern covers the path."""
    return _match(pattern.split("/"), path.split("/"))


def affects(patterns, paths):
    """True when any pattern covers any of the paths."""
    return any(matches(pattern, path) for pattern in patterns for path in paths)


def shared(path, root):
    """True when a change to the path runs every suite. `root` holds the names
    the BASE commit has at the root of the repository."""
    if path.startswith("tests/") and not path.endswith(".test.sh"):
        return True
    # A name Python can import that the root did not have: a folder, or a file
    # named up to its first dot, whatever follows it.
    top, below, _ = path.partition("/")
    name = top if below else top.split(".")[0]
    if top not in root and name.isidentifier():
        return True
    return affects(GLOBAL_INPUTS, [path])


def normalise(path):
    """The map names a suite without the leading `./` the workflow uses."""
    return path[2:] if path.startswith("./") else path


def suites(candidates):
    """The suites this pull request can affect.

    Every failure returns the whole candidate list, because a wrong skip lets
    a change merge untested and a wrong run costs seconds."""
    paths = changed_paths()
    if paths is None:
        return list(candidates)
    try:
        body = git("show", "HEAD^1:" + MAP)
        listing = git("ls-tree", "-z", "--name-only", "HEAD^1")
    except (OSError, subprocess.CalledProcessError):
        # No map in the base commit: the scope cannot be established.
        return list(candidates)
    scope = parse_map(body.decode("utf-8", "replace"))
    root = {os.fsdecode(name) for name in listing.split(b"\0") if name}
    if scope is None or any(shared(path, root) for path in paths):
        return list(candidates)
    keep = []
    for candidate in candidates:
        patterns = scope.get(candidate)
        if patterns is None:
            # The map does not know this suite, so it always runs.
            keep.append(candidate)
            continue
        # A suite that changes is a suite whose verdict can change, whether or
        # not its entry lists its own file.
        if candidate in paths or affects(patterns, paths):
            keep.append(candidate)
    return keep


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] != "suites":
        raise ValueError("this resolver only answers in the `suites` mode")
    # Always operate at the root, including for a shell working-directory.
    os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel")).strip())
    # The list of suites to run, one per line. The caller is the step of
    # .github/workflows/tests.yml that runs the suites, which passes the suites
    # the job names.
    for name in suites([normalise(a) for a in argv[1:]]):
        print(name)


try:
    main()
except (OSError, ValueError, subprocess.CalledProcessError) as exc:
    # Fail open: the whole list of suites the caller named, and nothing when the
    # caller named none. This script refuses nothing: a decision it could not
    # take is not a failure of the job, it is the whole list of suites.
    print(f"Cannot establish the suite scope; running every suite: {exc}", file=sys.stderr)
    for name in sys.argv[2:]:
        print(name)
PY
