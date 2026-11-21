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
import glob, re, sys, yaml

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
    elif rule == "interpreter":
        # A script in this repository is run as `bash scripts/x.sh`, so nothing in
        # production depends on its execute bit, which git has lost here before.
        call = re.compile(r"(?<![\w/.$:-])(?:\./)?((?:scripts|\.github/scripts)/[\w/.-]+\.(?:sh|py))")
        for job, cfg in (doc.get("jobs") or {}).items():
            for step in cfg.get("steps") or []:
                for line in str(step.get("run", "")).split("\n"):
                    if line.lstrip().startswith("#"):
                        continue
                    for m in call.finditer(line):
                        before = line[:m.start()].rstrip()
                        if not re.search(r"(?:^|[\s(`;|&])(?:bash|python3?|sh)$", before):
                            print(f"{name}: {job} runs {m.group(1)} without an interpreter")
    elif rule == "runners":
        # ubuntu-latest moves when GitHub moves it, and it moved to 26.04 while the
        # arm64 label stayed on 24.04. A job that runs this repository's scripts or
        # the image's own tools names the image it was measured on. The jobs below
        # only call gh or read strings, and are the only ones left on the moving label.
        only_gh = {
            ("build-check.yml", "gate"), ("dependabot-automerge.yml", "arm"),
            ("dependabot-automerge.yml", "disarm"), ("dependabot-automerge.yml", "rebase"),
            ("release.yml", "alert"), ("watchdog.yml", "alert"),
        }
        pinned = {"ubuntu-26.04", "ubuntu-24.04-arm", "${{ inputs.runner }}"}
        for job, cfg in (doc.get("jobs") or {}).items():
            runs_on = cfg.get("runs-on")
            # A job that calls a reusable workflow has no runner of its own, but its
            # matrix can hand one down.
            if runs_on is not None and (name, job) in only_gh:
                if runs_on != "ubuntu-latest":
                    print(f"{name}: {job} only calls gh and is listed as left on ubuntu-latest, it runs on {runs_on}")
            elif runs_on is not None and runs_on not in pinned:
                print(f"{name}: {job} runs on {runs_on}")
            for entry in ((cfg.get("strategy") or {}).get("matrix") or {}).get("include") or []:
                if entry.get("runner") not in pinned:
                    print(f"{name}: {job} builds {entry.get('arch')} on {entry.get('runner')}")
PY
}

# --- the repository has only main -------------------------------------------------
check "no workflow triggers on a branch other than main" "" "$(violations branches)"
BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i '0,/branches: \["main"\]/s//branches: ["main", "develop"]/' "$BAD/dco.yml"
check "a trigger on develop is named" "dco.yml: pull_request triggers on branch develop" "$(violations branches "$BAD")"

# --- the image a job runs on is named -------------------------------------------
check "every job that depends on the image names it" "" "$(violations runners)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^    runs-on: ubuntu-26.04$/    runs-on: ubuntu-latest/' "$BAD/tests.yml"
check "a pinned job moved back to ubuntu-latest is named" "tests.yml: test runs on ubuntu-latest" "$(violations runners "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/runner: ubuntu-26.04 }/runner: ubuntu-latest }/' "$BAD/release.yml"
check "a build matrix on ubuntu-latest is named" "release.yml: build builds amd64 on ubuntu-latest" "$(violations runners "$BAD")"

# --- repository scripts are run through an interpreter ---------------------------
check "no workflow runs a repository script by its execute bit" "" "$(violations interpreter)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's#bash scripts/quality/check-test-coverage.sh#scripts/quality/check-test-coverage.sh#' "$BAD/tests.yml"
check "a script called without bash is named" \
	"tests.yml: test runs scripts/quality/check-test-coverage.sh without an interpreter" "$(violations interpreter "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's#\$(bash scripts/build/recipe-id.sh)#$(scripts/build/recipe-id.sh)#' "$BAD/release.yml"
check "so is one inside a command substitution" \
	"release.yml: plan runs scripts/build/recipe-id.sh without an interpreter" "$(violations interpreter "$BAD")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
