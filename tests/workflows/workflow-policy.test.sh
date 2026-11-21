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
    elif rule == "concurrency":
        # A run on a pull request that a newer push has overtaken answers about a commit
        # that no longer exists, so the workflow cancels it. The group is the workflow's, or
        # the job's, or the reusable workflow's the job calls. The jobs below are the only
        # ones left out, each for a condition that is stated here and checked by "never-
        # cancelled": disarm takes a merge back, so another run must never cut it short, and
        # rebase runs on a push to main, where nothing is cancelled.
        exempt = {("dependabot-automerge.yml", "disarm"), ("dependabot-automerge.yml", "rebase")}
        if not set(triggers(doc)) & {"pull_request", "pull_request_target"}:
            continue
        def cancels(block):
            return str(block.get("cancel-in-progress", False)).strip().lower() != "false"
        top = doc.get("concurrency")
        if top is not None:
            if not cancels(top):
                print(f"{name}: concurrency does not cancel a superseded run")
            continue
        for job, cfg in (doc.get("jobs") or {}).items():
            if (name, job) in exempt:
                continue
            block = cfg.get("concurrency")
            uses = str(cfg.get("uses", ""))
            if block is None and uses.startswith("./.github/workflows/"):
                with open(f"{root}/{uses.rsplit('/', 1)[1]}") as reusable:
                    block = (yaml.safe_load(reusable) or {}).get("concurrency")
            if block is None:
                print(f"{name}: {job} runs on a pull request with no concurrency")
            elif not cancels(block):
                print(f"{name}: {job} concurrency does not cancel a superseded run")
    elif rule == "cancel-outside-pr":
        # A run that a newer one cancels is a verdict nobody gets. On a pull request the
        # newer push makes it moot; on a push to main each commit is its own, and two
        # merges in a row would leave the first without one. So a workflow that can run
        # on any event but a pull request cancels only when the event is one. A reusable
        # workflow runs on the events of its callers, read here from the files that use
        # it; one nobody calls is read as able to run on anything. A job whose own `if`
        # names only pull request events is read as running on them alone.
        pr_events = {"pull_request", "pull_request_target"}
        def only_pr(cfg):
            named = set(re.findall(r"github\.event_name\s*==\s*'([a-z_]+)'", str(cfg.get("if", ""))))
            return bool(named) and named <= pr_events
        def events_of(doc, fname):
            ev = set(triggers(doc))
            if "workflow_call" not in ev:
                return ev
            ev.discard("workflow_call")
            called = False
            for other in sorted(glob.glob(f"{root}/*.yml")):
                with open(other) as fh:
                    odoc = yaml.safe_load(fh)
                for cfg in (odoc.get("jobs") or {}).values():
                    if str(cfg.get("uses", "")) == f"./.github/workflows/{fname}" and not only_pr(cfg):
                        called = True
                        ev |= events_of(odoc, other.rsplit("/", 1)[1])
            return ev if called else ev | {"unknown caller"}
        def conditional(block):
            value = str(block.get("cancel-in-progress", False)).strip()
            return value.lower() == "false" or ("github.event_name" in value and "pull_request" in value)
        blocks = [("workflow", doc.get("concurrency"), True)]
        blocks += [(job, cfg.get("concurrency"), not only_pr(cfg)) for job, cfg in (doc.get("jobs") or {}).items()]
        outside = sorted(events_of(doc, name) - pr_events)
        for where, block, reachable in blocks:
            if block is not None and reachable and outside and not conditional(block):
                print(f"{name}: {where} cancels a run whatever the event, and the workflow also runs on {', '.join(outside)}")
    elif rule == "target-group":
        # On pull_request_target the ref is main for every pull request, so a group built
        # on it would let one pull request's run cancel another's.
        if "pull_request_target" not in triggers(doc):
            continue
        blocks = [("workflow", doc.get("concurrency"))] + [(j, c.get("concurrency")) for j, c in (doc.get("jobs") or {}).items()]
        for where, block in blocks:
            group = str((block or {}).get("group", ""))
            if "github.ref" in group:
                print(f"{name}: {where} groups pull_request_target runs by ref, which is main for every pull request")
    elif rule == "never-cancelled":
        # disarm turns auto-merge off after a person pushed to a Dependabot branch. A
        # newer run that cancelled it, and then declined to arm, would leave the merge on.
        if name != "dependabot-automerge.yml":
            continue
        if doc.get("concurrency") is not None:
            print(f"{name}: a workflow-level concurrency can cancel the disarm job")
        for job in ("disarm", "rebase"):
            block = ((doc.get("jobs") or {}).get(job) or {}).get("concurrency")
            # Whatever cancel-in-progress says: a pending run of a group is cancelled by
            # the next one queued behind it, and the setting that cancels a run in
            # progress belongs to the run that arrives, not to the one it finds.
            if block is not None:
                print(f"{name}: {job} is in a concurrency group, and a group can cancel it")
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

# --- a superseded run on a pull request is cancelled ----------------------------
check "every workflow that runs on a pull request cancels the runs a push overtook" "" "$(violations concurrency)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i '/^concurrency:/,/^$/d' "$BAD/commit-hygiene.yml"
check "a workflow with no concurrency is named, job by job" \
	"commit-hygiene.yml: commit-identity runs on a pull request with no concurrency
commit-hygiene.yml: secret-scan runs on a pull request with no concurrency" "$(violations concurrency "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^  cancel-in-progress: true$/  cancel-in-progress: false/' "$BAD/build-check.yml"
check "one that no longer cancels is named" "build-check.yml: concurrency does not cancel a superseded run" "$(violations concurrency "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i '/^concurrency:/,/^$/d' "$BAD/reusable-dco.yml"
check "the group of a reusable workflow a caller uses counts, and its absence is named" "dco.yml: dco runs on a pull request with no concurrency" "$(violations concurrency "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i '/^    concurrency:$/,/^      cancel-in-progress: true$/d' "$BAD/dependabot-automerge.yml"
check "arm, which has its own group, is named when it loses it" "dependabot-automerge.yml: arm runs on a pull request with no concurrency" "$(violations concurrency "$BAD")"

check "no pull_request_target group is built on the ref" "" "$(violations target-group)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/-arm-\${{ github.event.pull_request.number }}/-arm-${{ github.ref }}/' "$BAD/dependabot-automerge.yml"
check "a group on the ref of a pull_request_target run is named" \
	"dependabot-automerge.yml: arm groups pull_request_target runs by ref, which is main for every pull request" "$(violations target-group "$BAD")"

check "nothing can cancel the disarm and rebase jobs" "" "$(violations never-cancelled)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^permissions: {}$/permissions: {}\n\nconcurrency:\n  group: all\n  cancel-in-progress: true/' "$BAD/dependabot-automerge.yml"
check "a group over the whole workflow is named" "dependabot-automerge.yml: a workflow-level concurrency can cancel the disarm job" "$(violations never-cancelled "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^    name: disarm when a person pushes$/    name: disarm when a person pushes\n    concurrency:\n      group: d\n      cancel-in-progress: true/' "$BAD/dependabot-automerge.yml"
check "a cancelling group on the disarm job is named" "dependabot-automerge.yml: disarm is in a concurrency group, and a group can cancel it" "$(violations never-cancelled "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^    name: disarm when a person pushes$/    name: disarm when a person pushes\n    concurrency:\n      group: d\n      cancel-in-progress: false/' "$BAD/dependabot-automerge.yml"
check "and so is one that says it never cancels: a pending run of it is still cancelled by the next" \
	"dependabot-automerge.yml: disarm is in a concurrency group, and a group can cancel it" "$(violations never-cancelled "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^    name: rebase what fell behind$/    name: rebase what fell behind\n    concurrency:\n      group: r\n      cancel-in-progress: false/' "$BAD/dependabot-automerge.yml"
check "and the rebase job is held to the same" \
	"dependabot-automerge.yml: rebase is in a concurrency group, and a group can cancel it" "$(violations never-cancelled "$BAD")"

# --- a run is cancelled only on a pull request ---------------------------------
check "nothing that can run on a push, a schedule or a call cancels whatever the event" "" "$(violations cancel-outside-pr)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i "s/^  cancel-in-progress: \${{ github.event_name == 'pull_request' }}\$/  cancel-in-progress: true/" "$BAD/reusable-workflow-lint.yml"
check "the fixture did go back to cancelling always" "1" "$(grep -c '^  cancel-in-progress: true$' "$BAD/reusable-workflow-lint.yml")"
check "a reusable that its push caller can reach, cancelling always, is named" \
	"reusable-workflow-lint.yml: workflow cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i "s/^  cancel-in-progress: \${{ github.event_name == 'pull_request' }}\$/  cancel-in-progress: true/" "$BAD/reusable-line-limit.yml"
check "the same change to a reusable that only pull request callers use is accepted" "" "$(violations cancel-outside-pr "$BAD")"
sed -i 's/^  pull_request:$/  push:\n    branches: ["main"]\n  pull_request:/' "$BAD/line-limit.yml"
check "the fixture did give its caller a push trigger" "1" "$(grep -c '^  push:$' "$BAD/line-limit.yml")"
check "and is named once a caller can run it on a push" \
	"reusable-line-limit.yml: workflow cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
rm "$BAD/dco.yml"
check "a reusable that nothing calls is read as able to run on anything" \
	"reusable-dco.yml: workflow cancels a run whatever the event, and the workflow also runs on unknown caller" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^  pull_request:$/  push:\n    branches: ["main"]\n  pull_request:/' "$BAD/build-check.yml"
check "a workflow of its own that gains a push trigger and cancels always is named" \
	"build-check.yml: workflow cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i "s/ == 'pull_request_target' && github.event.pull_request.user.login/ != 'x' \&\& github.event.pull_request.user.login/" "$BAD/dependabot-automerge.yml"
check "the fixture did free the arm job from its event" "0" "$(grep -c "event_name == 'pull_request_target' && github.event.pull_request.user" "$BAD/dependabot-automerge.yml")"
check "a job that stopped naming a pull request event, in a workflow that has a push, is named" \
	"dependabot-automerge.yml: arm cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"

# --- a watcher does not run on a pull request ------------------------------------
check "the watchdog and the keyring watch do not trigger on a pull request" "" "$(violations watchers)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^  push:$/  pull_request:\n    branches: ["main"]\n  push:/' "$BAD/watchdog.yml"
check "a pull_request trigger on the watchdog is named" "watchdog.yml: triggers on pull_request, and a pull request cannot change what it reads" "$(violations watchers "$BAD")"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i '/^  schedule:$/,/^    - cron: /d' "$BAD/watchdog.yml"
check "the fixture did lose its schedule" "0" "$(grep -c '^  schedule:$' "$BAD/watchdog.yml")"
check "a watchdog without its schedule is named, and so is the alarm that waits for it" \
	"watchdog.yml: has no schedule, so nothing runs it when nobody pushes|watchdog.yml: a condition waits for the event schedule, which the workflow does not trigger on" \
	"$(violations watchers "$BAD" | paste -sd'|')"

# --- a timeout says what it was measured from ------------------------------------
check "every timeout-minutes has its measurement, or says it is a ceiling" "" "$(violations timeouts)"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i '/Ceiling, not measured: two gh calls\./d' "$BAD/release.yml"
check "a timeout with no comment above it is named, with its line" "release.yml:N: timeout-minutes has no 'Measured' or 'Ceiling, not measured' comment above it" \
	"$(violations timeouts "$BAD" | sed 's/^\([a-z.-]*\):[0-9]*:/\1:N:/')"
cp "$HERE"/.github/workflows/*.yml "$BAD/"
sed -i 's/^    # Measured in this repository.s runs: 6 to 8 seconds, with the six ls-remote calls$/    # The plan is quick, with the six ls-remote calls/' "$BAD/release.yml"
check "a comment that says neither is named" "release.yml:N: timeout-minutes has no 'Measured' or 'Ceiling, not measured' comment above it" \
	"$(violations timeouts "$BAD" | sed 's/^\([a-z.-]*\):[0-9]*:/\1:N:/')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
