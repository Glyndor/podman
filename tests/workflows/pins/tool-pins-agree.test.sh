#!/usr/bin/env bash
#
# The linters CI downloads are pinned by version and by sha256, and the pin of shellcheck
# is written in two workflows and named in two documents: tests.yml, the input defaults of
# reusable-workflow-lint.yml (where actionlint runs it), CONTRIBUTING.md and the pull
# request template. A comment in tests.yml says that they "move together"; nothing made
# them. Two jobs on two shellchecks give two verdicts on the same code, which is what the
# pin exists to stop, and Dependabot reads neither (a tarball fetched with curl is not a
# package of any ecosystem it knows), so the pins only move when a person moves them and
# the second place is the one that gets forgotten.
#
# Read from the files: every pin of shellcheck and of actionlint, in a step's env or in an
# input default, has to agree on the version and the hash, be a tag and a 64 digit hash,
# and sit where it is expected; the documents name the same version. Each rule is run on the
# real files and on copies that break it one way each.
#
# What this does not do, and says so: it does not know that a version is the newest, nor
# that a hash belongs to the version beside it (that takes the network, and the install step
# refuses a mismatch when it runs). Nothing tells anyone that a release is out.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <repository root>: one line per violation. A rule that cannot run prints
# "rule failed", so a crash is never read as none.
violations() {
	python3 -I - "$1" 2>&1 <<'PY' || echo "rule failed"
import glob, os, re, sys, yaml

root = sys.argv[1]
TAG = re.compile(r"^v\d+\.\d+\.\d+$")
SHA = re.compile(r"^[0-9a-f]{64}$")
# Where each tool has to be pinned. shellcheck runs in two places on purpose, one that
# checks this repository's scripts and one inside actionlint; actionlint in one.
EXPECTED = {
    "shellcheck": {"tests.yml", "reusable-workflow-lint.yml"},
    "actionlint": {"reusable-workflow-lint.yml"},
}
pins = {tool: {} for tool in EXPECTED}   # tool -> file -> {"version": ..., "sha256": ...}


def note(tool, name, field, value):
    pins[tool].setdefault(name, {})[field] = str(value)


for path in sorted(glob.glob(f"{root}/.github/workflows/*.yml") + glob.glob(f"{root}/.github/workflows/*.yaml")):
    name = os.path.basename(path)
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    for job in (doc.get("jobs") or {}).values():
        for step in job.get("steps") or []:
            for key, value in (step.get("env") or {}).items():
                m = re.match(r"^(SHELLCHECK|ACTIONLINT)_(VERSION|SHA256)$", key)
                if m and "${{" not in str(value):
                    note(m.group(1).lower(), name, m.group(2).lower(), value)
    triggers = doc.get("on") or doc.get(True) or {}
    inputs = (triggers.get("workflow_call") or {}).get("inputs") or {} if isinstance(triggers, dict) else {}
    for key, spec in inputs.items():
        m = re.match(r"^(shellcheck|actionlint)-(version|sha256)$", key)
        if m and isinstance(spec, dict) and "default" in spec:
            note(m.group(1), name, m.group(2), spec["default"])

for tool, expected in EXPECTED.items():
    for name in sorted(expected - set(pins[tool])):
        print(f"{tool}: {name} does not pin it, so that job runs whichever one the runner has")
    seen = {}
    for name, found in sorted(pins[tool].items()):
        for field, pattern, shape in (("version", TAG, "a release tag such as v0.11.0"), ("sha256", SHA, "64 hex digits")):
            if field not in found:
                print(f"{tool}: {name} pins a {'sha256' if field == 'version' else 'version'} and no {field}")
            elif not pattern.match(found[field]):
                print(f"{tool}: the {field} in {name} is {found[field]}, which is not {shape}")
            else:
                seen.setdefault(field, {}).setdefault(found[field], []).append(name)
    for field, values in sorted(seen.items()):
        if len(values) > 1:
            where = "; ".join(f"{value} in {', '.join(names)}" for value, names in sorted(values.items()))
            print(f"{tool}: the {field} is not the same everywhere: {where}")

# The documents say which shellcheck CI pins; they have to say the one that is.
versions = {found["version"] for found in pins["shellcheck"].values() if "version" in found}
documents = (
    ("CONTRIBUTING.md", r"shellcheck v?(\d+\.\d+\.\d+) \(the version CI pins\)"),
    (".github/PULL_REQUEST_TEMPLATE.md", r"shellcheck v?(\d+\.\d+\.\d+), the version CI pins"),
)
for rel, pattern in documents:
    with open(f"{root}/{rel}") as fh:
        said = re.findall(pattern, fh.read())
    if len(said) != 1:
        print(f"{rel}: names the pinned shellcheck {len(said)} time(s), not once")
    elif len(versions) == 1 and f"v{said[0]}" not in versions:
        print(f"{rel}: says shellcheck {said[0]} is what CI pins, and the workflows pin {next(iter(versions))}")
PY
}

BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
# fixture <file> <old> <new>: a copy of the files the rules read, with one text of one file
# replaced. The text has to be there exactly once, so a rule is never judged against a copy
# that still holds.
copy_tree() {
	rm -rf "$BAD"/.github "$BAD"/CONTRIBUTING.md; mkdir -p "$BAD/.github"
	cp -r "$HERE/.github/workflows" "$BAD/.github/"; cp "$HERE/.github/PULL_REQUEST_TEMPLATE.md" "$BAD/.github/"
	cp "$HERE/CONTRIBUTING.md" "$BAD/"
}
fixture() {
	copy_tree
	python3 -I - "$BAD/$1" "$2" "$3" <<'PY' || echo "FIXTURE INERT: $1 $2"
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
}

SC_VER_TESTS='SHELLCHECK_VERSION: v0.11.0'
SC_SHA_TESTS='SHELLCHECK_SHA256: 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198'
SC_VER_LINT='default: "v0.11.0"'
SC_SHA_LINT='default: "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"'
OTHER_SHA=1111111111111111111111111111111111111111111111111111111111111111

check "every pin of shellcheck and actionlint agrees, and the documents name the one CI uses" "" "$(violations "$HERE")"

# --- the two pins of shellcheck ----------------------------------------------------------
fixture .github/workflows/tests.yml "$SC_VER_TESTS" 'SHELLCHECK_VERSION: v0.12.0'
check "a version moved in tests.yml and not in the reusable is named, with where each is" \
	"shellcheck: the version is not the same everywhere: v0.11.0 in reusable-workflow-lint.yml; v0.12.0 in tests.yml" \
	"$(violations "$BAD" | grep '^shellcheck:')"
fixture .github/workflows/reusable-workflow-lint.yml "$SC_VER_LINT" 'default: "v0.12.0"'
check "and the other way round" \
	"shellcheck: the version is not the same everywhere: v0.11.0 in tests.yml; v0.12.0 in reusable-workflow-lint.yml" \
	"$(violations "$BAD" | grep '^shellcheck:')"
fixture .github/workflows/tests.yml "$SC_SHA_TESTS" "SHELLCHECK_SHA256: $OTHER_SHA"
check "a hash that differs between the two is named" \
	"shellcheck: the sha256 is not the same everywhere: $OTHER_SHA in tests.yml; 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 in reusable-workflow-lint.yml" \
	"$(violations "$BAD")"
fixture .github/workflows/reusable-workflow-lint.yml "$SC_SHA_LINT" "default: \"$OTHER_SHA\""
check "and in the reusable" \
	"shellcheck: the sha256 is not the same everywhere: $OTHER_SHA in reusable-workflow-lint.yml; 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 in tests.yml" \
	"$(violations "$BAD")"

# --- a pin that is gone, or is not one ----------------------------------------------------
fixture .github/workflows/tests.yml "$SC_VER_TESTS" 'SHELLCHECK_VERSION: ${{ vars.SHELLCHECK_VERSION }}'
check "a version taken from a variable, which nothing here can compare, is named" \
	"shellcheck: tests.yml pins a sha256 and no version" "$(violations "$BAD")"
fixture .github/workflows/tests.yml "$SC_SHA_TESTS" 'SHELLCHECK_SHA256: not-a-hash'
check "a hash that is not 64 hex digits is named" \
	"shellcheck: the sha256 in tests.yml is not-a-hash, which is not 64 hex digits" "$(violations "$BAD")"
fixture .github/workflows/tests.yml "$SC_VER_TESTS" 'SHELLCHECK_VERSION: latest'
check "a version that is not a tag is named" \
	"shellcheck: the version in tests.yml is latest, which is not a release tag such as v0.11.0" "$(violations "$BAD")"
copy_tree
python3 -I - "$BAD/.github/workflows/tests.yml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"          SHELLCHECK_VERSION: .*\n          SHELLCHECK_SHA256: .*\n", "", text)
open(path, "w").write(text)
PY
check "a tests.yml that stops pinning shellcheck, and takes the runner's, is named" \
	"shellcheck: tests.yml does not pin it, so that job runs whichever one the runner has" "$(violations "$BAD")"
fixture .github/workflows/reusable-workflow-lint.yml "$SC_SHA_LINT" 'default: ""'
check "an empty default is not a hash" \
	"shellcheck: the sha256 in reusable-workflow-lint.yml is , which is not 64 hex digits" "$(violations "$BAD")"

# --- actionlint, pinned in one place --------------------------------------------------------
fixture .github/workflows/reusable-workflow-lint.yml 'ACTIONLINT_SHA256: 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8' 'ACTIONLINT_SHA256: nope'
check "an actionlint hash that is not one is named" \
	"actionlint: the sha256 in reusable-workflow-lint.yml is nope, which is not 64 hex digits" "$(violations "$BAD")"
fixture .github/workflows/tests.yml '      - name: Install shellcheck
        env:' '      - name: Install actionlint too
        env:
          ACTIONLINT_VERSION: v1.7.1
          ACTIONLINT_SHA256: 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
      - name: Install shellcheck
        env:'
check "a second copy of the actionlint pin that disagrees is named" \
	"actionlint: the version is not the same everywhere: v1.7.1 in tests.yml; v1.7.12 in reusable-workflow-lint.yml" "$(violations "$BAD")"

# --- the documents ----------------------------------------------------------------------------
fixture CONTRIBUTING.md 'shellcheck 0.11.0 (the version CI pins)' 'shellcheck 0.10.0 (the version CI pins)'
check "CONTRIBUTING.md naming another version than the one CI pins is named" \
	"CONTRIBUTING.md: says shellcheck 0.10.0 is what CI pins, and the workflows pin v0.11.0" "$(violations "$BAD")"
fixture .github/PULL_REQUEST_TEMPLATE.md '(shellcheck v0.11.0, the version CI pins)' '(shellcheck v0.9.0, the version CI pins)'
check "so is the pull request template" \
	".github/PULL_REQUEST_TEMPLATE.md: says shellcheck 0.9.0 is what CI pins, and the workflows pin v0.11.0" "$(violations "$BAD")"
fixture CONTRIBUTING.md 'shellcheck 0.11.0 (the version CI pins)' 'shellcheck (the version CI pins)'
check "a document that stops naming the version is named too" \
	"CONTRIBUTING.md: names the pinned shellcheck 0 time(s), not once" "$(violations "$BAD")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
