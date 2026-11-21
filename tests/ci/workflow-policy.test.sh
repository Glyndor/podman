#!/usr/bin/env bash
#
# Rules every workflow file here has to keep, read from the files themselves so
# a workflow that drifts is a red test and not a surprise in a run. Each rule
# prints the offending file and job, so the failure names what to change.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <rule> [workflow-dir]: runs a rule over every workflow file and
# prints one line per violation. The directory is a parameter so a rule can be
# run against a copy that breaks it. A rule that cannot run prints "rule failed",
# so a crash is never read as "no violations".
violations() {
	python3 - "$1" "${2:-$HERE/.github/workflows}" 2>&1 <<'PY' || echo "rule failed"
import glob, sys, yaml

rule, root = sys.argv[1:3]

def triggers(doc):
    # PyYAML reads the key `on` as the boolean True.
    on = doc.get("on", doc.get(True)) or {}
    return on if isinstance(on, dict) else {}

for path in sorted(glob.glob(f"{root}/*.yml")):
    name = path.rsplit("/", 1)[1]
    with open(path) as fh:
        doc = yaml.safe_load(fh)
    if rule == "branches":
        # The repository has one branch. A trigger on another reads as coverage
        # of a branch that does not exist.
        for event, cfg in triggers(doc).items():
            if not isinstance(cfg, dict):
                continue
            for b in cfg.get("branches") or []:
                if b != "main":
                    print(f"{name}: {event} triggers on branch {b}")

PY
}

# --- the repository has only main -------------------------------------------------
check "no workflow triggers on a branch other than main" "" "$(violations branches)"
BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i '0,/branches: \["main"\]/s//branches: ["main", "develop"]/' "$BAD/dco.yml"
check "a trigger on develop is named" "dco.yml: pull_request triggers on branch develop" "$(violations branches "$BAD")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
