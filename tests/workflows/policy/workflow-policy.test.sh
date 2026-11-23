#!/usr/bin/env bash
#
# Rules every workflow file here has to keep, read from the files themselves so
# a workflow that drifts is a red test and not a surprise in a run. Each rule
# prints the offending file and job, so the failure names what to change. The
# rules about concurrency are in concurrency-policy.test.sh, and least privilege
# and pins in least-privilege.test.sh.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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

for path in sorted(glob.glob(f"{root}/*.yml") + glob.glob(f"{root}/*.yaml")):
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
    elif rule == "watchers":
        # These only read upstream, the releases and the runs: a pull request cannot change
        # what they find, and each run on one is network calls for nothing.
        events = set(triggers(doc))
        if name in ("watchdog.yml", "keyring-watch.yml"):
            for event in sorted(events & {"pull_request", "pull_request_target"}):
                print(f"{name}: triggers on {event}, and a pull request cannot change what it reads")
            if "schedule" not in events:
                print(f"{name}: has no schedule, so nothing runs it when nobody pushes")
        # A condition on an event the workflow never receives is a step that never runs:
        # an alarm that waits for the schedule in a workflow without one stays silent.
        # A reusable workflow sees the caller's event, so it is not read.
        if "workflow_call" not in events:
            waited = set(re.findall(r"github\.event_name\s*==\s*'([a-z_]+)'", open(path).read()))
            for event in sorted(waited - events):
                print(f"{name}: a condition waits for the event {event}, which the workflow does not trigger on")
    elif rule == "timeouts":
        # The number says how long the job is allowed; the line above says why: what was
        # measured, or that nothing was and the number is a ceiling.
        lines = open(path).read().split("\n")
        for i, line in enumerate(lines):
            if not re.match(r"\s+timeout-minutes:\s*\d+\s*$", line):
                continue
            above = []
            j = i - 1
            while j >= 0 and lines[j].lstrip().startswith("#"):
                above.append(lines[j])
                j -= 1
            if not re.search(r"\bMeasured\b|\bCeiling, not measured\b", " ".join(above)):
                print(f"{name}:{i + 1}: timeout-minutes has no 'Measured' or 'Ceiling, not measured' comment above it")
    elif rule == "runners":
        # ubuntu-latest moves when GitHub moves it, and it moved to 26.04 while the
        # arm64 label stayed on 24.04. A job that runs this repository's scripts or
        # the image's own tools names the image it was measured on. The jobs below
        # only call gh or read strings, and are the only ones left on the moving label.
        only_gh = {
            ("build-check.yml", "gate"), ("package-check.yml", "gate"), ("dependabot-automerge.yml", "arm"),
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
            include = ((cfg.get("strategy") or {}).get("matrix") or {}).get("include") or []
            # A matrix read from a script at run time is a string: its runners are held to the
            # pinned list by the suite of that script.
            for entry in [] if isinstance(include, str) else include:
                if entry.get("runner") not in pinned:
                    print(f"{name}: {job} builds {entry.get('arch')} on {entry.get('runner')}")
            # One call for each architecture, with no matrix: the runner is an input of the call.
            handed = (cfg.get("with") or {}).get("runner")
            if handed is not None and handed not in pinned and not str(handed).startswith("${{"):
                print(f"{name}: {job} builds {(cfg.get('with') or {}).get('arch')} on {handed}")
PY
}

# --- the repository has only main -------------------------------------------------
check "no workflow triggers on a branch other than main" "" "$(violations branches)"
BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i '0,/branches: \["main"\]/s//branches: ["main", "develop"]/' "$BAD/dco.yml"
check "a trigger on develop is named" "dco.yml: pull_request triggers on branch develop" "$(violations branches "$BAD")"

# --- the image a job runs on is named -------------------------------------------
check "every job that depends on the image names it" "" "$(violations runners)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^    runs-on: ubuntu-26.04$/    runs-on: ubuntu-latest/' "$BAD/tests.yml"
check "a pinned job moved back to ubuntu-latest is named" "tests.yml: test runs on ubuntu-latest" "$(violations runners "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i '0,/^      runner: ubuntu-26.04$/s//      runner: ubuntu-latest/' "$BAD/release.yml"
check "a build on ubuntu-latest is named" "release.yml: build-amd64 builds amd64 on ubuntu-latest" "$(violations runners "$BAD")"

# --- repository scripts are run through an interpreter ---------------------------
check "no workflow runs a repository script by its execute bit" "" "$(violations interpreter)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's#bash scripts/quality/check-test-coverage.sh#scripts/quality/check-test-coverage.sh#' "$BAD/tests.yml"
check "a script called without bash is named" \
	"tests.yml: test runs scripts/quality/check-test-coverage.sh without an interpreter" "$(violations interpreter "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's#\$(bash scripts/build/recipe-id.sh)#$(scripts/build/recipe-id.sh)#' "$BAD/release.yml"
check "so is one inside a command substitution" \
	"release.yml: plan runs scripts/build/recipe-id.sh without an interpreter" "$(violations interpreter "$BAD")"

# --- a watcher does not run on a pull request ------------------------------------
check "the watchdog and the keyring watch do not trigger on a pull request" "" "$(violations watchers)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^  push:$/  pull_request:\n    branches: ["main"]\n  push:/' "$BAD/watchdog.yml"
check "a pull_request trigger on the watchdog is named" "watchdog.yml: triggers on pull_request, and a pull request cannot change what it reads" "$(violations watchers "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i '/^  schedule:$/,/^    - cron: /d' "$BAD/watchdog.yml"
check "the fixture did lose its schedule" "0" "$(grep -c '^  schedule:$' "$BAD/watchdog.yml")"
check "a watchdog without its schedule is named, and so is the alarm that waits for it" \
	"watchdog.yml: has no schedule, so nothing runs it when nobody pushes|watchdog.yml: a condition waits for the event schedule, which the workflow does not trigger on" \
	"$(violations watchers "$BAD" | paste -sd'|')"

# --- a timeout says what it was measured from ------------------------------------
check "every timeout-minutes has its measurement, or says it is a ceiling" "" "$(violations timeouts)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i '/Ceiling, not measured: two gh calls\./d' "$BAD/release.yml"
check "a timeout with no comment above it is named, with its line" "release.yml:N: timeout-minutes has no 'Measured' or 'Ceiling, not measured' comment above it" \
	"$(violations timeouts "$BAD" | sed 's/^\([a-z.-]*\):[0-9]*:/\1:N:/')"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^    # Measured in this repository.s runs: 6 to 8 seconds, with the six ls-remote calls$/    # The plan is quick, with the six ls-remote calls/' "$BAD/release.yml"
check "a comment that says neither is named" "release.yml:N: timeout-minutes has no 'Measured' or 'Ceiling, not measured' comment above it" \
	"$(violations timeouts "$BAD" | sed 's/^\([a-z.-]*\):[0-9]*:/\1:N:/')"

# --- a workflow named .yaml is read too -----------------------------------------
# GitHub runs .yaml files as well as .yml, so a rule that globbed one would not see
# a workflow that a pull request adds under the other. Last, since the copy keeps it.
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
printf 'on:\n  push:\n    branches: ["develop"]\njobs: {}\n' > "$BAD/extra.yaml"
check "a .yaml workflow is held to the rules" "extra.yaml: push triggers on branch develop" "$(violations branches "$BAD")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
