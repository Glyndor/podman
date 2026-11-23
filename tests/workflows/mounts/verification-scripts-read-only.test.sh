#!/usr/bin/env bash
#
# What a container of the build can write, read from the `docker run` lines of every
# workflow here.
#
# reusable-build.yml compiles third-party code (the make of Podman, netavark and
# aardvark-dns) in a container that runs as root and mounts $GITHUB_WORKSPACE/scripts, the
# directory of the repository on the runner. The smoke test that decides whether the
# package is signed runs afterwards, in other containers, from the same directory. If the
# first mount could write, that code could rewrite scripts/verify/smoke-test.sh to `exit 0`
# and the package would be published, signed, with every suite green: the `:ro` on four
# mounts is the only thing between the two, and it is not a refusal, so the mutation check
# does not read it. Two rules, each run on the real files and on copies that break it:
#   workspace   a mount whose source is in the workspace is read-only
#   writable    a mount that is not read-only is on the list below, with the step that
#               holds it; an entry that no step asks for any more is named too
# and a count, so a rule that read nothing cannot pass: each step mounts the scripts
# directory as many times as it has `docker run` lines that need it.
#
# Not covered, and said so: a mount built from a shell variable, which the text of the step
# does not show, and `--volumes-from`. Neither appears in the workflows today.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations [workflow-dir]: one line per violation over every workflow file. A rule that
# cannot run prints "rule failed", so a crash is never read as none.
violations() {
	python3 -I - "${1:-$HERE/.github/workflows}" 2>&1 <<'PY' || echo "rule failed"
import glob, re, shlex, sys, yaml

root = sys.argv[1]
SCRIPTS = "$GITHUB_WORKSPACE/scripts"
# The writable mounts, by file, step and source, and why. The build compiles the three
# upstream trees in place and writes the package to /out; no other container writes
# anything it mounts. Read from the workflows on 2026-11-21.
WRITABLE = {
    ("reusable-build.yml", "Build the package", "$RUNNER_TEMP/podman"): "make writes the build tree of Podman",
    ("reusable-build.yml", "Build the package", "$RUNNER_TEMP/netavark"): "cargo writes the build tree of netavark",
    ("reusable-build.yml", "Build the package", "$RUNNER_TEMP/aardvark"): "cargo writes the build tree of aardvark-dns",
    ("reusable-build.yml", "Build the package", "$RUNNER_TEMP/out"): "the package is written here",
}
# How many times each step mounts the scripts directory, which is once for every
# `docker run` that runs a script from it.
SCRIPT_MOUNTS = {
    ("reusable-build.yml", "Build the package"): 1,
    ("reusable-build.yml", "Smoke-test the package on Debian 13 and Ubuntu 24.04 and 26.04"): 2,
    ("reusable-build.yml", "Check an older release refuses the package"): 1,
    ("release.yml", "Upgrade from it without losing an edited policy.json"): 1,
}
CHAINS = {";", "&&", "||", "|", "&", "(", ")"}


def in_workspace(src):
    return bool(re.search(r"GITHUB_WORKSPACE|github\.workspace|\$PWD|\$\(pwd\)|`pwd`", src)) \
        or src == "." or src.startswith("./")


def mounts_of(run):
    """(source, destination, read-only) of every mount of every `docker run` or `docker create`."""
    found = []
    text = re.sub(r"\\\n", " ", run)
    for line in text.split("\n"):
        if line.lstrip().startswith("#"):
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        try:
            tokens = list(lexer)
        except ValueError:
            continue
        for at, word in enumerate(tokens):
            if word != "docker" or tokens[at + 1:at + 2] not in (["run"], ["create"]):
                continue
            end = at + 2
            while end < len(tokens) and tokens[end] not in CHAINS:
                end += 1
            args = tokens[at + 2:end]
            for n, arg in enumerate(args):
                nxt = args[n + 1] if n + 1 < len(args) else ""
                if arg in ("-v", "--volume") or arg.startswith("--volume="):
                    spec = arg.split("=", 1)[1] if arg.startswith("--volume=") else nxt
                    parts = spec.split(":")
                    options = parts[2].split(",") if len(parts) > 2 else []
                    found.append((parts[0], parts[1] if len(parts) > 1 else "", "ro" in options))
                elif arg == "--mount" or arg.startswith("--mount="):
                    spec = arg.split("=", 1)[1] if arg.startswith("--mount=") else nxt
                    fields = {}
                    for item in spec.split(","):
                        key, _, value = item.partition("=")
                        fields[key] = value
                    off = {"false", "0"}
                    readonly = any(k in fields and fields[k] not in off for k in ("readonly", "ro"))
                    found.append((fields.get("src") or fields.get("source") or "", fields.get("dst") or fields.get("target") or "", readonly))
    return found


used = set()
counted = {}
steps_seen = set()
for path in sorted(glob.glob(f"{root}/*.yml") + glob.glob(f"{root}/*.yaml")):
    name = path.rsplit("/", 1)[1]
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    for job in (doc.get("jobs") or {}).values():
        for number, step in enumerate(job.get("steps") or [], 1):
            if "run" not in step:
                continue
            label = step.get("name") or f"step {number}"
            steps_seen.add((name, label))
            for src, dst, readonly in mounts_of(str(step["run"])):
                if src == SCRIPTS:
                    counted[(name, label)] = counted.get((name, label), 0) + 1
                if in_workspace(src) and not readonly:
                    print(f"{name}: {label} mounts {src} from the workspace and it is writable")
                elif not readonly:
                    if (name, label, src) in WRITABLE:
                        used.add((name, label, src))
                    else:
                        print(f"{name}: {label} mounts {src} writable, which no entry of the list allows")
for key, want in sorted(SCRIPT_MOUNTS.items()):
    if key not in steps_seen:
        print(f"{key[0]}: no step named {key[1]}, which the count reads")
    elif counted.get(key, 0) != want:
        print(f"{key[0]}: {key[1]} mounts the scripts directory {counted.get(key, 0)} time(s), not {want}")
for name, label, src in sorted(set(WRITABLE) - used):
    print(f"{name}: {label} is allowed to mount {src} writable and does not; remove the entry")
PY
}

BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
# fixture <file> <old> <new>: a copy of the workflows with one text of one file replaced. The
# text has to be there exactly once, so a rule is never judged against a copy that still
# holds, or against the wrong line of two that read alike.
fixture() {
	rm -f "$BAD"/*; cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
	python3 -I - "$BAD/$1" "$2" "$3" <<'PY' || echo "FIXTURE INERT: $1 $2"
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
}

BUILD='-v "$RUNNER_TEMP/aardvark:/src/aardvark" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" \'
SMOKE1='-v "$RUNNER_TEMP/out:/out:ro" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" "podman-deb-$target" \'
SMOKE2='-v "$GITHUB_WORKSPACE/scripts:/scripts:ro" -v "$RUNNER_TEMP/out:/out:ro" "podman-deb-$target" \'
REFUSE='-v "$RUNNER_TEMP/out:/out:ro" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" podman-deb-ubuntu2204 \'
rw() { printf '%s' "${1//scripts:\/scripts:ro/scripts:\/scripts}"; }
S1='reusable-build.yml: Build the package mounts $GITHUB_WORKSPACE/scripts from the workspace and it is writable'
S2='reusable-build.yml: Smoke-test the package on Debian 13 and Ubuntu 24.04 and 26.04 mounts $GITHUB_WORKSPACE/scripts from the workspace and it is writable'
S3='reusable-build.yml: Check an older release refuses the package mounts $GITHUB_WORKSPACE/scripts from the workspace and it is writable'

check "every mount of the workspace is read-only, the writable ones are on the list, and the count holds" "" "$(violations)"

# --- the four mounts of the scripts directory ----------------------------------------
fixture reusable-build.yml "$BUILD" "$(rw "$BUILD")"
check "the build container, which runs third-party code, given a writable scripts directory is named" "$S1" "$(violations "$BAD")"
fixture reusable-build.yml "$SMOKE1" "$(rw "$SMOKE1")"
check "so is the first smoke-test run" "$S2" "$(violations "$BAD")"
fixture reusable-build.yml "$SMOKE2" "$(rw "$SMOKE2")"
check "and the second" "$S2" "$(violations "$BAD")"
fixture reusable-build.yml "$REFUSE" "$(rw "$REFUSE")"
check "and the run that checks an older release refuses the package" "$S3" "$(violations "$BAD")"

# --- the other ways to make a workspace mount writable ---------------------------------
fixture reusable-build.yml "$BUILD" '-v "$RUNNER_TEMP/aardvark:/src/aardvark" -v "$GITHUB_WORKSPACE:/workspace" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" \'
check "the whole workspace mounted writable is named" \
	'reusable-build.yml: Build the package mounts $GITHUB_WORKSPACE from the workspace and it is writable' "$(violations "$BAD")"
fixture reusable-build.yml "$BUILD" '-v "$RUNNER_TEMP/aardvark:/src/aardvark" -v ./scripts:/more -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" \'
check "so is a relative path, which is the workspace too" \
	'reusable-build.yml: Build the package mounts ./scripts from the workspace and it is writable' "$(violations "$BAD")"
fixture reusable-build.yml "$BUILD" '-v "$RUNNER_TEMP/aardvark:/src/aardvark" --mount type=bind,src=$GITHUB_WORKSPACE/scripts,dst=/more -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" \'
check "so is a --mount that does not say readonly" "$S1
reusable-build.yml: Build the package mounts the scripts directory 2 time(s), not 1" "$(violations "$BAD")"
fixture reusable-build.yml "$BUILD" '-v "$RUNNER_TEMP/aardvark:/src/aardvark" --volume=$GITHUB_WORKSPACE/scripts:/more -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" \'
check "so is a --volume=, which is counted as a mount of the scripts as well" "$S1
reusable-build.yml: Build the package mounts the scripts directory 2 time(s), not 1" "$(violations "$BAD")"

# --- a mount that is not the workspace -------------------------------------------------
fixture reusable-build.yml "$SMOKE1" '-v "$RUNNER_TEMP/out:/out" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" "podman-deb-$target" \'
check "the package under test mounted writable in the smoke test is named" \
	'reusable-build.yml: Smoke-test the package on Debian 13 and Ubuntu 24.04 and 26.04 mounts $RUNNER_TEMP/out writable, which no entry of the list allows' "$(violations "$BAD")"
fixture reusable-build.yml "$REFUSE" '-v /var/run/docker.sock:/var/run/docker.sock -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" podman-deb-ubuntu2204 \'
check "a mount of anything else, writable, is named" \
	'reusable-build.yml: Check an older release refuses the package mounts /var/run/docker.sock writable, which no entry of the list allows' "$(violations "$BAD")"
fixture reusable-build.yml '-v "$RUNNER_TEMP/netavark:/src/netavark"' '-v "$RUNNER_TEMP/netavark:/src/netavark:ro"'
check "an entry of the list that the step no longer asks for is named" \
	'reusable-build.yml: Build the package is allowed to mount $RUNNER_TEMP/netavark writable and does not; remove the entry' "$(violations "$BAD")"

# --- what is accepted, the same shapes just inside the rule ----------------------------
fixture reusable-build.yml "$REFUSE" '--mount type=bind,src=$GITHUB_WORKSPACE/scripts,dst=/scripts,readonly --mount type=bind,src=$RUNNER_TEMP/out,dst=/out,readonly podman-deb-ubuntu2204 \'
check "a --mount with readonly is as good as :ro" "" "$(violations "$BAD")"
fixture reusable-build.yml "$REFUSE" '-v "$RUNNER_TEMP/out:/out:ro" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro,z" podman-deb-ubuntu2204 \'
check "and :ro with another option beside it, which is the same mount in other words" "" "$(violations "$BAD")"

# --- a step that does not mount the scripts at all, and a workflow of another name -----
fixture reusable-build.yml "$REFUSE" '-v "$RUNNER_TEMP/out:/out:ro" podman-deb-ubuntu2204 \'
check "a step that stops mounting the scripts is named by the count" \
	'reusable-build.yml: Check an older release refuses the package mounts the scripts directory 0 time(s), not 1' "$(violations "$BAD")"
rm -f "$BAD"/*; cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
cat > "$BAD/extra.yaml" <<'YAML'
on: push
permissions: {}
jobs:
  sneak:
    runs-on: ubuntu-26.04
    steps:
      - name: Run something
        run: |
          docker run --rm -v "$GITHUB_WORKSPACE/scripts:/scripts" some-image
YAML
check "a .yaml workflow that mounts the scripts writable is named" \
	'extra.yaml: Run something mounts $GITHUB_WORKSPACE/scripts from the workspace and it is writable' "$(violations "$BAD")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
