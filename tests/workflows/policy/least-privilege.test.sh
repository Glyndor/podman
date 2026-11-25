#!/usr/bin/env bash
#
# Least privilege, for every workflow file here, read from the files themselves:
#   permissions  each workflow declares its permissions, read at most, and every write
#                a job holds is one the list below allows, with the reason it needs
#                it; an entry of the list that no job asks for any more is named too,
#                so the list says what is true today
#   credentials  every actions/checkout passes persist-credentials: false, so the job
#                token is not written to .git/config beside the code the job runs. The
#                job that pushes (keyring-watch.yml) hands git the token in a header
#                for that one command instead.
#   pins         every action and reusable workflow of another repository is pinned to
#                a full commit SHA with its version in a comment beside it, as in
#                `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`. A
#                tag is whatever its owner points it at tomorrow, and the code it names
#                runs with the job's token, in release.yml beside the signing keys. A
#                reusable of this repository (./.github/workflows/) is the same commit.
#                A value the rule cannot find on a line of its own is named too, since
#                its comment cannot be read.
# The build job compiles third-party code, and either rule loosened there (contents:
# write, or the token left on disk) passed every suite until this one. Each rule runs
# on the real files and on copies that break it one way each.
#
# workflow-policy.test.sh holds the other rules over the same files; this one is a
# suite of its own so neither grows past the soft limit of line-limit.yml.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <rule> [workflow-dir]: one line per violation over every workflow file.
# A rule that cannot run prints "rule failed", so a crash is never read as none.
violations() {
	python3 - "$1" "${2:-$HERE/.github/workflows}" 2>&1 <<'PY' || echo "rule failed"
import glob, re, sys, yaml

rule, root = sys.argv[1:3]
PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
USES_LINE = re.compile(r"""^\s*(?:-\s+)?uses:\s*(['"]?)([^'"\s#]+)\1\s*(?:#\s*(\S.*?))?\s*$""")
VERSION = re.compile(r"^v\d+(\.\d+)*$")

# Every write a job holds, and why. Read from what each job does on 2026-11-21.
ALLOWED = {
    ("release.yml", "publish", "contents"): "creates the release and uploads its assets",
    ("release.yml", "publish", "id-token"): "the token the provenance attestation is signed with",
    ("release.yml", "publish", "attestations"): "stores the provenance attestation",
    ("release.yml", "alert", "issues"): "opens the issue when a release run fails",
    ("dependabot-automerge.yml", "arm", "contents"): "gh pr merge --auto merges into main",
    ("dependabot-automerge.yml", "arm", "pull-requests"): "arms auto-merge on the pull request",
    ("dependabot-automerge.yml", "disarm", "pull-requests"): "turns auto-merge off after a person pushed",
    ("dependabot-automerge.yml", "rebase", "pull-requests"): "asks Dependabot to rebase in a comment",
    ("keyring-watch.yml", "compare", "contents"): "pushes the branch with the new upstream keys",
    ("keyring-watch.yml", "compare", "issues"): "opens the issue that links that branch",
    ("keyring-watch.yml", "health", "issues"): "opens the issue when too few keys stay valid",
    ("watchdog.yml", "alert", "issues"): "opens the issue when the release is behind upstream",
    ("watchdog.yml", "keyring-watch-freshness", "issues"): "opens the issue when the keyring watch stopped",
    ("watchdog.yml", "mutation-freshness", "issues"): "opens the issue when the mutation sweep stopped",
    ("watchdog.yml", "tool-versions", "issues"): "opens the issue when a pinned linter is behind upstream",
}
LEVELS = {"read", "write", "none"}

used = set()
for path in sorted(glob.glob(f"{root}/*.yml") + glob.glob(f"{root}/*.yaml")):
    name = path.rsplit("/", 1)[1]
    with open(path) as fh:
        text = fh.read()
    doc = yaml.safe_load(text) or {}
    jobs = doc.get("jobs") or {}
    if rule == "permissions":
        top = doc.get("permissions")
        if top is None:
            print(f"{name}: declares no permissions for the workflow, so every job gets the repository default")
            top = {}
        elif not isinstance(top, dict):
            print(f"{name}: the workflow grants {top}; name each permission")
            top = {}
        for scope, level in top.items():
            if level != "read" and level != "none":
                print(f"{name}: the workflow grants {scope}: {level} to every job")
        for job, cfg in jobs.items():
            perms = cfg.get("permissions", top)
            if not isinstance(perms, dict):
                print(f"{name}: {job} holds {perms}; name each permission")
                continue
            for scope, level in perms.items():
                if level not in LEVELS:
                    print(f"{name}: {job} holds {scope}: {level}, which is not read, write or none")
                elif level == "write":
                    if (name, job, scope) in ALLOWED:
                        used.add((name, job, scope))
                    else:
                        print(f"{name}: {job} holds {scope}: write, which no entry of the list allows")
    elif rule == "credentials":
        for job, cfg in jobs.items():
            for step in cfg.get("steps") or []:
                # Every spelling GitHub runs as the checkout action: pinned or not, and
                # in any case, since owner and repository names are not case sensitive.
                action = str(step.get("uses", "")).split("@", 1)[0].strip().rstrip("/").lower()
                if action != "actions/checkout":
                    continue
                keep = (step.get("with") or {}).get("persist-credentials")
                if str(keep).strip().lower() != "false":
                    print(f"{name}: {job} checks out without persist-credentials: false")
    elif rule == "pins":
        used = []
        for job, cfg in jobs.items():
            if "uses" in cfg:
                used.append((job, str(cfg["uses"])))
            used += [(job, str(step["uses"])) for step in cfg.get("steps") or [] if "uses" in step]
        comments = {}
        for line in text.split("\n"):
            m = USES_LINE.match(line)
            if m:
                comments.setdefault(m.group(2), []).append(m.group(3) or "")
        for job, value in used:
            if value.startswith("./"):
                continue
            if not PINNED.match(value):
                print(f"{name}: {job} uses {value}, which is not pinned to a full commit SHA")
            elif not comments.get(value):
                print(f"{name}: {job} uses {value} on no line of its own, so its version comment cannot be read")
            elif not all(VERSION.match(c) for c in comments[value]):
                print(f"{name}: {job} uses {value} with no version comment beside it")
if rule == "permissions":
    for name, job, scope in sorted(set(ALLOWED) - used):
        print(f"{name}: {job} is allowed {scope}: write and does not ask for it; remove the entry")
PY
}

BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
# fixture <file> <sed expression>: a copy of the workflows with one file changed. A
# change that does nothing is reported, so a rule is never judged against a copy that
# still holds.
fixture() {
	rm -f "$BAD"/*; cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
	sed -i "$2" "$BAD/$1"
	cmp -s "$BAD/$1" "$HERE/.github/workflows/$1" && echo "FIXTURE INERT: $1 $2"
}

# --- permissions ------------------------------------------------------------------
check "every workflow declares read at most, and every write is on the list" "" "$(violations permissions)"
fixture reusable-build.yml '0,/^    permissions:$/{/^    permissions:$/{n;s/contents: read/contents: write/}}'
check "the build job, which runs third-party code, given contents: write is named" \
	"reusable-build.yml: build holds contents: write, which no entry of the list allows" "$(violations permissions "$BAD")"
fixture release.yml '/^  build-amd64:$/,/^  sign:$/s/^      contents: read$/      contents: write/'
check "so are the jobs that call it" "release.yml: build-amd64 holds contents: write, which no entry of the list allows
release.yml: build-arm64 holds contents: write, which no entry of the list allows" "$(violations permissions "$BAD")"
fixture dco.yml 's/^  contents: read$/  contents: write/'
check "a write granted to a whole workflow is named" "dco.yml: the workflow grants contents: write to every job
dco.yml: dco holds contents: write, which no entry of the list allows" "$(violations permissions "$BAD")"
fixture tests.yml '/^permissions: {}$/d'
check "a workflow with no permissions of its own is named" \
	"tests.yml: declares no permissions for the workflow, so every job gets the repository default" "$(violations permissions "$BAD")"
fixture tests.yml 's/^permissions: {}$/permissions: write-all/'
check "a workflow that grants everything is named" "tests.yml: the workflow grants write-all; name each permission" "$(violations permissions "$BAD")"
fixture release.yml '/^  alert:$/,$s/^      issues: write$/      issues: read/'
check "an entry of the list that no job asks for any more is named" \
	"release.yml: alert is allowed issues: write and does not ask for it; remove the entry" "$(violations permissions "$BAD")"
fixture watchdog.yml '/^  delivery-lag:$/,/^  alert:$/s/^      contents: read$/      contents: read\n      issues: write/'
check "and a write the list allows to another job of the same file is still named" \
	"watchdog.yml: delivery-lag holds issues: write, which no entry of the list allows" "$(violations permissions "$BAD")"

# --- credentials ------------------------------------------------------------------
check "every checkout passes persist-credentials: false" "" "$(violations credentials)"
fixture reusable-build.yml '0,/^          persist-credentials: false$/s//          fetch-depth: 1/'
check "the build job's checkout keeping the token, with another option in its place, is named" \
	"reusable-build.yml: build checks out without persist-credentials: false" "$(violations credentials "$BAD")"
fixture keyring-watch.yml '0,/^          persist-credentials: false$/s//          persist-credentials: true/'
check "so is the job that pushes, which hands git the token in a header instead" \
	"keyring-watch.yml: compare checks out without persist-credentials: false" "$(violations credentials "$BAD")"
fixture tests.yml '/^          persist-credentials: false$/d'
check "and a checkout left with no options at all" "tests.yml: test checks out without persist-credentials: false" "$(violations credentials "$BAD")"
fixture tests.yml '/^          persist-credentials: false$/d; s/^      - uses: actions\/checkout@.*$/      - uses: actions\/checkout/'
check "and one that is not pinned, which the pins rule refuses for the pin" \
	"tests.yml: test checks out without persist-credentials: false" "$(violations credentials "$BAD")"
fixture tests.yml '/^          persist-credentials: false$/d; s/^      - uses: actions\/checkout@/      - uses: Actions\/Checkout@/'
check "and one that spells the action with capitals, which GitHub runs all the same" \
	"tests.yml: test checks out without persist-credentials: false" "$(violations credentials "$BAD")"

# --- pins -------------------------------------------------------------------------
check "every action from another repository is pinned to a SHA, with its version" "" "$(violations pins)"
fixture tests.yml 's/^      - uses: actions\/checkout@.*$/      - uses: actions\/checkout/'
check "an action with no ref at all is named" \
	"tests.yml: test uses actions/checkout, which is not pinned to a full commit SHA" "$(violations pins "$BAD")"
fixture tests.yml 's/^      - uses: actions\/checkout@.*$/      - uses: actions\/checkout@v7.0.1/'
check "an action pinned to a tag is named" \
	"tests.yml: test uses actions/checkout@v7.0.1, which is not pinned to a full commit SHA" "$(violations pins "$BAD")"
fixture tests.yml 's/@3d3c42e5aac5ba805825da76410c181273ba90b1/@3d3c42e/'
check "an action pinned to a short SHA is named" \
	"tests.yml: test uses actions/checkout@3d3c42e, which is not pinned to a full commit SHA" "$(violations pins "$BAD")"
upload='actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'
fixture reusable-build.yml 's/^\(        uses: actions\/upload-artifact@[0-9a-f]*\) # v7.0.2$/\1/'
check "a pinned action with no version comment is named" \
	"reusable-build.yml: build uses $upload with no version comment beside it" "$(violations pins "$BAD")"
fixture reusable-build.yml 's/ # v7.0.2$/ # the upload/'
check "and so is one whose comment is not a version" \
	"reusable-build.yml: build uses $upload with no version comment beside it" "$(violations pins "$BAD")"
fixture line-limit.yml 's#^    uses: ./.github/workflows/reusable-line-limit.yml$#    uses: Glyndor/.github/.github/workflows/line-limit.yml@main#'
check "a reusable workflow of another repository is held to the same" \
	"line-limit.yml: line-limit uses Glyndor/.github/.github/workflows/line-limit.yml@main, which is not pinned to a full commit SHA" \
	"$(violations pins "$BAD")"

# --- a workflow named .yaml is a workflow too ---------------------------------------
rm -f "$BAD"/*; cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
cat > "$BAD/extra.yaml" <<'YAML'
on: push
permissions:
  contents: read
jobs:
  sneak:
    runs-on: ubuntu-26.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
YAML
check "a .yaml workflow that writes is named" "extra.yaml: sneak holds contents: write, which no entry of the list allows" "$(violations permissions "$BAD")"
check "and so is its checkout that keeps the token" "extra.yaml: sneak checks out without persist-credentials: false" "$(violations credentials "$BAD")"
cat > "$BAD/extra.yaml" <<'YAML'
on: push
permissions: {}
jobs:
  sneak:
    runs-on: ubuntu-26.04
    steps:
      - {uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1}
      - uses: "actions/upload-artifact@v7"
YAML
check "and its pins: a flow mapping is named, and so is a quoted tag" \
	"extra.yaml: sneak uses actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 on no line of its own, so its version comment cannot be read|extra.yaml: sneak uses actions/upload-artifact@v7, which is not pinned to a full commit SHA" \
	"$(violations pins "$BAD" | paste -sd'|')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
