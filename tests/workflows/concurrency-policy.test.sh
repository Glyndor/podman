#!/usr/bin/env bash
#
# The concurrency of every workflow file here, read from the files themselves: a run
# on a pull request that a newer push overtook is cancelled; nothing that runs on a
# push, a schedule or a call is cancelled by the next run; a pull_request_target run
# is grouped by its pull request and not by the ref, which is main for all of them;
# the jobs that take a merge back are in no group; and a push run is in a group of
# its own, so the next push cannot cancel it while it waits. workflow-policy.test.sh
# holds the other rules over the same files; this one is a suite of its own so
# neither grows past the soft limit of line-limit.yml. Each rule prints the offending
# file and job, and each is run against copies that break it one way each.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <rule> [workflow-dir]: runs a rule over every workflow file and prints one
# line per violation. A rule that cannot run prints "rule failed", so a crash is never
# read as "no violations".
violations() {
	python3 - "$1" "${2:-$HERE/.github/workflows}" 2>&1 <<'PY' || echo "rule failed"
import glob, re, sys, yaml

rule, root = sys.argv[1:3]

def triggers(doc):
    # PyYAML reads the key `on` as the boolean True.
    on = doc.get("on", doc.get(True)) or {}
    return on if isinstance(on, dict) else {}

pr_events = {"pull_request", "pull_request_target"}

def only_pr(cfg):
    # A job whose own `if` names only pull request events runs on them alone.
    named = set(re.findall(r"github\.event_name\s*==\s*'([a-z_]+)'", str(cfg.get("if", ""))))
    return bool(named) and named <= pr_events

def events_of(doc, fname):
    # A reusable workflow runs on the events of its callers, read from the files that
    # use it; one nobody calls is read as able to run on anything.
    ev = set(triggers(doc))
    if "workflow_call" not in ev:
        return ev
    ev.discard("workflow_call")
    called = False
    for other in sorted(glob.glob(f"{root}/*.yml") + glob.glob(f"{root}/*.yaml")):
        with open(other) as fh:
            odoc = yaml.safe_load(fh)
        for cfg in (odoc.get("jobs") or {}).values():
            if str(cfg.get("uses", "")) == f"./.github/workflows/{fname}" and not only_pr(cfg):
                called = True
                ev |= events_of(odoc, other.rsplit("/", 1)[1])
    return ev if called else ev | {"unknown caller"}

for path in sorted(glob.glob(f"{root}/*.yml") + glob.glob(f"{root}/*.yaml")):
    name = path.rsplit("/", 1)[1]
    with open(path) as fh:
        doc = yaml.safe_load(fh)
    if rule == "concurrency":
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
    elif rule == "push-group":
        # GitHub keeps at most one pending run per concurrency group and cancels it when
        # the next one is queued, whatever cancel-in-progress says. A group that pushes
        # to main share loses the verdict of a push that waited behind another: of three
        # merges in a row, the middle one is never checked, and the push is the only run
        # that says main is green. So a group a push can reach is made of the run id. The
        # one exception is release.yml, serialised on purpose: two release runs at once
        # would race for the same tag, and a pending one that is replaced loses nothing,
        # since the run after it plans from upstream and the releases again.
        exempt = {("release.yml", "workflow")}
        # A reusable workflow is written for callers this repository does not hold, so a
        # push is within reach of every one of them, whatever the callers here run on.
        if "push" not in events_of(doc, name) and "workflow_call" not in triggers(doc):
            continue
        blocks = [("workflow", doc.get("concurrency"))]
        blocks += [(job, cfg.get("concurrency")) for job, cfg in (doc.get("jobs") or {}).items() if not only_pr(cfg)]
        for where, block in blocks:
            if block is None or (name, where) in exempt:
                continue
            group = str(block.get("group", ""))
            if "github.run_id" not in group:
                print(f"{name}: {where} groups push runs by {group!r}, so a push can cancel the one queued before it")
PY
}

BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT

# --- a superseded run on a pull request is cancelled ----------------------------
check "every workflow that runs on a pull request cancels the runs a push overtook" "" "$(violations concurrency)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i '/^concurrency:/,/^$/d' "$BAD/commit-hygiene.yml"
check "a workflow with no concurrency is named, job by job" \
	"commit-hygiene.yml: commit-identity runs on a pull request with no concurrency
commit-hygiene.yml: secret-scan runs on a pull request with no concurrency" "$(violations concurrency "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^  cancel-in-progress: true$/  cancel-in-progress: false/' "$BAD/build-check.yml"
check "one that no longer cancels is named" "build-check.yml: concurrency does not cancel a superseded run" "$(violations concurrency "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i '/^concurrency:/,/^$/d' "$BAD/reusable-dco.yml"
check "the group of a reusable workflow a caller uses counts, and its absence is named" "dco.yml: dco runs on a pull request with no concurrency" "$(violations concurrency "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i '/^    concurrency:$/,/^      cancel-in-progress: true$/d' "$BAD/dependabot-automerge.yml"
check "arm, which has its own group, is named when it loses it" "dependabot-automerge.yml: arm runs on a pull request with no concurrency" "$(violations concurrency "$BAD")"

check "no pull_request_target group is built on the ref" "" "$(violations target-group)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/-arm-\${{ github.event.pull_request.number }}/-arm-${{ github.ref }}/' "$BAD/dependabot-automerge.yml"
check "a group on the ref of a pull_request_target run is named" \
	"dependabot-automerge.yml: arm groups pull_request_target runs by ref, which is main for every pull request" "$(violations target-group "$BAD")"

check "nothing can cancel the disarm and rebase jobs" "" "$(violations never-cancelled)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^permissions: {}$/permissions: {}\n\nconcurrency:\n  group: all\n  cancel-in-progress: true/' "$BAD/dependabot-automerge.yml"
check "a group over the whole workflow is named" "dependabot-automerge.yml: a workflow-level concurrency can cancel the disarm job" "$(violations never-cancelled "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^    name: disarm when a person pushes$/    name: disarm when a person pushes\n    concurrency:\n      group: d\n      cancel-in-progress: true/' "$BAD/dependabot-automerge.yml"
check "a cancelling group on the disarm job is named" "dependabot-automerge.yml: disarm is in a concurrency group, and a group can cancel it" "$(violations never-cancelled "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^    name: disarm when a person pushes$/    name: disarm when a person pushes\n    concurrency:\n      group: d\n      cancel-in-progress: false/' "$BAD/dependabot-automerge.yml"
check "and so is one that says it never cancels: a pending run of it is still cancelled by the next" \
	"dependabot-automerge.yml: disarm is in a concurrency group, and a group can cancel it" "$(violations never-cancelled "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^    name: rebase what fell behind$/    name: rebase what fell behind\n    concurrency:\n      group: r\n      cancel-in-progress: false/' "$BAD/dependabot-automerge.yml"
check "and the rebase job is held to the same" \
	"dependabot-automerge.yml: rebase is in a concurrency group, and a group can cancel it" "$(violations never-cancelled "$BAD")"

# --- a run is cancelled only on a pull request ---------------------------------
check "nothing that can run on a push, a schedule or a call cancels whatever the event" "" "$(violations cancel-outside-pr)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i "s/^  cancel-in-progress: \${{ github.event_name == 'pull_request' }}\$/  cancel-in-progress: true/" "$BAD/reusable-workflow-lint.yml"
check "the fixture did go back to cancelling always" "1" "$(grep -c '^  cancel-in-progress: true$' "$BAD/reusable-workflow-lint.yml")"
check "a reusable that its push caller can reach, cancelling always, is named" \
	"reusable-workflow-lint.yml: workflow cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i "s/^  cancel-in-progress: \${{ github.event_name == 'pull_request' }}\$/  cancel-in-progress: true/" "$BAD/reusable-line-limit.yml"
check "the same change to a reusable that only pull request callers use is accepted" "" "$(violations cancel-outside-pr "$BAD")"
sed -i 's/^  pull_request:$/  push:\n    branches: ["main"]\n  pull_request:/' "$BAD/line-limit.yml"
check "the fixture did give its caller a push trigger" "1" "$(grep -c '^  push:$' "$BAD/line-limit.yml")"
check "and is named once a caller can run it on a push" \
	"reusable-line-limit.yml: workflow cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
rm "$BAD/dco.yml"
check "a reusable that nothing calls, cancelling only on a pull request, is accepted" "" "$(violations cancel-outside-pr "$BAD")"
sed -i "s/^  cancel-in-progress: \${{ github.event_name == 'pull_request' }}\$/  cancel-in-progress: true/" "$BAD/reusable-dco.yml"
check "the fixture did go back to cancelling always" "1" "$(grep -c '^  cancel-in-progress: true$' "$BAD/reusable-dco.yml")"
check "a reusable that nothing calls is read as able to run on anything" \
	"reusable-dco.yml: workflow cancels a run whatever the event, and the workflow also runs on unknown caller" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^  pull_request:$/  push:\n    branches: ["main"]\n  pull_request:/' "$BAD/build-check.yml"
check "a workflow of its own that gains a push trigger and cancels always is named" \
	"build-check.yml: workflow cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i "s/ == 'pull_request_target' && github.event.pull_request.user.login/ != 'x' \&\& github.event.pull_request.user.login/" "$BAD/dependabot-automerge.yml"
check "the fixture did free the arm job from its event" "0" "$(grep -c "event_name == 'pull_request_target' && github.event.pull_request.user" "$BAD/dependabot-automerge.yml")"
check "a job that stopped naming a pull request event, in a workflow that has a push, is named" \
	"dependabot-automerge.yml: arm cancels a run whatever the event, and the workflow also runs on push" "$(violations cancel-outside-pr "$BAD")"

# --- a push run is never cancelled by the next push --------------------------------
check "every group a push can reach is the run's own" "" "$(violations push-group)"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i "s/^  group: tests-\${{ github.event_name == 'pull_request' \&\& github.ref || github.run_id }}\$/  group: tests-\${{ github.ref }}/" "$BAD/tests.yml"
check "the fixture did group the push runs of tests.yml by ref" 1 "$(grep -c '^  group: tests-\${{ github.ref }}$' "$BAD/tests.yml")"
check "a push group built on the ref is named" \
	"tests.yml: workflow groups push runs by 'tests-\${{ github.ref }}', so a push can cancel the one queued before it" "$(violations push-group "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i "s/^  group: workflow-lint-\${{ github.workflow }}-.*\$/  group: workflow-lint-\${{ github.workflow }}-\${{ github.ref }}/" "$BAD/reusable-workflow-lint.yml"
check "and so is one in a reusable workflow that a push caller runs" \
	"reusable-workflow-lint.yml: workflow groups push runs by 'workflow-lint-\${{ github.workflow }}-\${{ github.ref }}', so a push can cancel the one queued before it" \
	"$(violations push-group "$BAD")"
for reusable in reusable-dco reusable-line-limit; do
	cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
	sed -i "s/^  group: \(.*\)-\${{ github.event_name == 'pull_request' && github.ref || github.run_id }}\$/  group: \1-\${{ github.ref }}/" "$BAD/$reusable.yml"
	check "the fixture did group the runs of $reusable.yml by ref" 1 "$(grep -c '^  group: .*-\${{ github.ref }}$' "$BAD/$reusable.yml")"
	check "$reusable.yml, which only pull request callers use here, is named for it" \
		"$reusable.yml: workflow groups push runs by '$(sed -n 's/^  group: //p' "$BAD/$reusable.yml")', so a push can cancel the one queued before it" \
		"$(violations push-group "$BAD")"
done
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^  group: release$/  group: release-${{ github.ref }}/' "$BAD/release.yml"
check "release.yml, serialised on purpose, is the one group left out" "" "$(violations push-group "$BAD")"
cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
sed -i 's/^permissions: {}$/permissions: {}\n\nconcurrency:\n  group: watchdog\n  cancel-in-progress: false/' "$BAD/watchdog.yml"
check "a fixed group on a workflow with a push trigger is named, whatever cancel-in-progress says" \
	"watchdog.yml: workflow groups push runs by 'watchdog', so a push can cancel the one queued before it" "$(violations push-group "$BAD")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
