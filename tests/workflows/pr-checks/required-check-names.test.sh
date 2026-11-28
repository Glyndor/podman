#!/usr/bin/env bash
#
# The checks of a pull request, read from the workflows that produce them.
#
# GitHub matches a required status check by name and by nothing else: the check a
# pull request waits for can be produced by any run on the same commit, by any
# workflow and any event. A workflow of a pull request that also runs on a push
# therefore answers for a pull request with a run that never judged it, and two
# jobs that produce the same name answer for each other.
#
# So this repository holds three things, and the planted workflows below break each:
#
#   * every workflow file is in a list, with the events it may run on: a workflow of
#     a pull request runs on pull_request and on nothing else, and a workflow that
#     runs on a push, a schedule or by hand is one the list names, with the reason;
#   * the check names the workflows produce are in a list too, each with the
#     workflow that produces it: a name no list declares, a name that belongs to
#     another workflow and a name that is declared and not produced are all named;
#   * a name the ruleset of main waits for is produced only by a workflow that runs
#     on a pull request and on no push.
#
# The names a matrix names are not in the list: the distribution and the
# architecture of a row are read at run time, and the rows change with the list of
# distributions. A name that holds an expression is skipped, and a workflow that
# produces one is not asked to declare it.
#
# Requires: python3 with PyYAML.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# The workflows of this repository and the events each of them may run on. The
# workflows of a pull request run on pull_request alone. The others run on what
# they are for: the publication on a schedule and on the push that changes the
# recipe, the watchers on a schedule and by hand, the auto-merge of Dependabot on
# the pull request it arms and on the push that says a person took over.
EVENTS="build-check.yml	pull_request
commit-hygiene.yml	pull_request
deprecations.yml	pull_request
dco.yml	pull_request
dependabot-automerge.yml	pull_request_target push
keyring-watch.yml	schedule workflow_dispatch
line-limit.yml	pull_request
mutation.yml	pull_request schedule workflow_dispatch
package-check.yml	pull_request
release.yml	schedule push workflow_dispatch
tests.yml	pull_request workflow_call
watchdog.yml	schedule push workflow_dispatch
workflow-lint.yml	pull_request"

# The check names that matter, the workflows that produce them and whether the
# ruleset of main waits for them. The gate of each workflow is the name it waits
# for; the jobs under it are not checks of their own. The decision job of the
# three gate workflows is called decide and the plan under it plan: they are steps
# of the gate, and a name that three of them use cannot stand in for a check, so
# they are written here with the three that produce them.
NAMES="commit identity	commit-hygiene.yml	yes
deprecations	deprecations.yml	yes
dco / Signed-off-by present on every commit	dco.yml	yes
every catalogued guard is noticed	mutation.yml	yes
full suite / test	mutation.yml	no
line-limit / line limit	line-limit.yml	yes
package builds	build-check.yml	yes
packages build	package-check.yml	no
secret scan	commit-hygiene.yml	yes
test	tests.yml	yes
workflow-lint / workflow-lint	workflow-lint.yml	yes
decide	build-check.yml,mutation.yml,package-check.yml	no
plan	build-check.yml,package-check.yml	no
rpm / list	package-check.yml	no
rpm / gather	package-check.yml	no
sweep	mutation.yml	no"

printf '%s\n' "$EVENTS" > "$WORK/events.tsv"
printf '%s\n' "$NAMES" > "$WORK/names.tsv"

# offences <workflow dir>: one line per offence over the workflows of the directory.
# A rule that cannot run prints "the rule failed", so a crash is never read as none.
offences() {
	python3 - "$1" "$WORK/events.tsv" "$WORK/names.tsv" 2>&1 <<'PY' || echo "the rule failed"
import glob, os, sys, yaml

root, events_path, names_path = sys.argv[1:4]


def table(path):
    rows = []
    for line in open(path, encoding="utf-8").read().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        rows.append(line.split("\t"))
    return rows


EVENTS = {row[0]: set(row[1].split()) for row in table(events_path)}
NAMES = {row[0]: (row[1].split(","), row[2]) for row in table(names_path)}
DYNAMIC = "${{"


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def triggers(doc):
    # PyYAML reads the key `on` as the boolean True.
    on = doc.get("on", doc.get(True)) or {}
    if isinstance(on, dict):
        return set(on)
    if isinstance(on, str):
        return {on}
    return set(on or [])


paths = sorted(glob.glob(f"{root}/*.yml") + glob.glob(f"{root}/*.yaml"))
files = {os.path.basename(path): load(path) for path in paths}
# The names the jobs of a reusable produce, so the caller of one is named after them.
inner = {}
for name, doc in files.items():
    if "workflow_call" in triggers(doc):
        inner[name] = {job: str(cfg.get("name", job)) for job, cfg in (doc.get("jobs") or {}).items()}


def produced(doc):
    """The check names the jobs of a workflow produce."""
    names = []
    for job, cfg in (doc.get("jobs") or {}).items():
        uses = str(cfg.get("uses", ""))
        # A caller of a reusable is named `<caller job id> / <inner job name>`.
        caller = str(cfg.get("name", job))
        if uses.startswith("./.github/workflows/"):
            for inner_name in inner.get(uses.rsplit("/", 1)[1], {}).values():
                names.append(f"{caller} / {inner_name}")
        else:
            names.append(caller)
    return names


offences = []
for name in sorted(EVENTS):
    if name not in files:
        offences.append(f"{name} is in the list of the workflows and it is not there")
for name, doc in sorted(files.items()):
    if name.startswith("reusable-"):
        continue
    if name not in EVENTS:
        offences.append(f"{name} is not in the list of the workflows of this repository")
    else:
        seen = triggers(doc)
        if seen != EVENTS[name]:
            offences.append(f"{name} runs on {', '.join(sorted(seen)) or 'nothing'}, "
                            f"not on {', '.join(sorted(EVENTS[name]))}")
    for produced_name in produced(doc):
        if DYNAMIC in produced_name:
            continue
        if produced_name in NAMES:
            owners = NAMES[produced_name][0]
            if name not in owners:
                offences.append(f"{name} produces the check name '{produced_name}', "
                                f"which is declared for {', '.join(owners)}")
        elif name in EVENTS and "pull_request" in EVENTS[name]:
            offences.append(f"{name} produces the check name '{produced_name}', which no list declares")
for produced_name, (owners, required) in sorted(NAMES.items()):
    for owner in owners:
        doc = files.get(owner)
        if doc is None or produced_name not in produced(doc):
            offences.append(f"the check name '{produced_name}' is not produced by {owner}")
    if required == "yes":
        for owner in owners:
            doc = files.get(owner)
            if doc is not None and "push" in triggers(doc):
                offences.append(f"the check name '{produced_name}' is produced by {owner}, which also runs on a push")
for message in offences:
    print(message)
PY
}

# A copy of the workflows of this repository, to plant a change in.
copy() { # <name>: the directory that holds the copy
	rm -rf "$WORK/${1:?}"
	mkdir -p "$WORK/$1/.github"
	cp -r "$HERE/.github/workflows" "$WORK/$1/.github/workflows"
	echo "$WORK/$1/.github/workflows"
}

check "the workflows produce the names the list declares, each one, on a pull request alone" "" \
	"$(offences "$HERE/.github/workflows")"

d="$(copy push)"
python3 - "$d/tests.yml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(
    "on:\n  pull_request:", "on:\n  push:\n    branches: [\"main\"]\n  pull_request:", 1))
PY
check "a push trigger on the workflow of a pull request is named" "1" \
	"$(offences "$d" | grep -c "tests.yml runs on pull_request, push")"
check "and the check it produces is named as one a push answers" "1" \
	"$(offences "$d" | grep -c "the check name 'test' is produced by tests.yml, which also runs on a push")"

d="$(copy schedule)"
python3 - "$d/dco.yml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(
    "on:\n  pull_request:", "on:\n  schedule:\n    - cron: \"0 0 * * *\"\n  pull_request:", 1))
PY
check "a schedule trigger on the workflow of a pull request is named" "1" \
	"$(offences "$d" | grep -c "dco.yml runs on pull_request, schedule")"

d="$(copy second)"
printf 'on: pull_request\njobs:\n  other:\n    name: test\n    runs-on: ubuntu-26.04\n    steps: []\n' > "$d/other.yml"
check "a second workflow that produces the name of a check is named" "1" \
	"$(offences "$d" | grep -c "other.yml produces the check name 'test'")"
check "and the workflow nobody listed is named" "1" \
	"$(offences "$d" | grep -c "other.yml is not in the list of the workflows of this repository")"

d="$(copy renamed)"
sed -i 's/^    name: test$/    name: verdict/' "$d/tests.yml"
check "a renamed check is named on the side that produces it" "1" \
	"$(offences "$d" | grep -c "tests.yml produces the check name 'verdict', which no list declares")"
check "and on the side that declares it" "1" \
	"$(offences "$d" | grep -c "the check name 'test' is not produced by tests.yml")"

d="$(copy gone)"
rm "$d/dco.yml"
check "a workflow that is gone is named on both sides" "2" \
	"$(offences "$d" | grep -c "dco.yml is in the list of the workflows and it is not there\|the check name 'dco / Signed-off-by present on every commit' is not produced by dco.yml")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
