#!/usr/bin/env bash
#
# Tests that the table of workflows in CONTRIBUTING.md names every workflow file the
# repository has and no file it does not, and that the commands it gives run scripts
# through an interpreter, as the workflows must (workflow-policy.test.sh). The table is
# what a contributor reads to learn what can fail and why, and three of the files that
# hold the logic of three of its rows were missing from it, with nothing to say so.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# drift <guide> <workflow-dir>: one line per workflow file the table leaves out and per
# name in its first column that is not a file. A table that could not be read is a
# line too, never an empty answer.
drift() {
	python3 - "$1" "$2" <<'PY' 2>&1 || echo "rule failed"
import os, re, sys
guide, root = sys.argv[1:3]
rows = [l for l in open(guide).read().split("\n") if l.startswith("|")]
named = set()
for row in rows:
    first = row.split("|")[1]
    named.update(re.findall(r"`([\w.-]+\.yml)`", first))
if not named:
    print("no workflow file is named in the first column of any table row")
files = {f for f in os.listdir(root) if f.endswith(".yml")}
for f in sorted(files - named):
    print(f"{f} is a workflow and the table does not name it")
for f in sorted(named - files):
    print(f"{f} is in the table and is not a workflow")
PY
}

check "the table names every workflow file and no other" "" "$(drift "$HERE/CONTRIBUTING.md" "$HERE/.github/workflows")"

mkdir -p "$WORK/wf"
: > "$WORK/wf/one.yml"; : > "$WORK/wf/two.yml"
printf '| file | what fails there |\n|---|---|\n| `one.yml`, `two.yml` | both |\n' > "$WORK/guide.md"
check "two files named in one row are both counted" "" "$(drift "$WORK/guide.md" "$WORK/wf")"
: > "$WORK/wf/three.yml"
check "a workflow the table leaves out is named" "three.yml is a workflow and the table does not name it" "$(drift "$WORK/guide.md" "$WORK/wf")"
rm "$WORK/wf/three.yml" "$WORK/wf/two.yml"
check "a row for a file that is gone is named" "two.yml is in the table and is not a workflow" "$(drift "$WORK/guide.md" "$WORK/wf")"
printf 'no table here\n' > "$WORK/guide.md"
check "a guide with no table is a finding, not a pass" "no workflow file is named in the first column of any table row
one.yml is a workflow and the table does not name it" "$(drift "$WORK/guide.md" "$WORK/wf")"

# --- the release row names what starts the release -------------------------------
# paths_missing <guide> <release.yml>: each path whose change starts a push run of the
# release, as its row of the table names it (scripts/build/** as scripts/build, the
# workflow files by their file name).
paths_missing() {
	python3 - "$1" "$2" <<'PY' 2>&1 || echo "rule failed"
import re, sys, yaml
guide, workflow = sys.argv[1:3]
doc = yaml.safe_load(open(workflow))
paths = (doc.get("on", doc.get(True)) or {}).get("push", {}).get("paths") or []
if not paths:
    print("release.yml has no push paths to compare with")
row = [l for l in open(guide).read().split("\n") if l.startswith("| `release.yml`")]
if len(row) != 1:
    sys.exit(f"{len(row)} rows for release.yml in {guide}")
for p in paths:
    name = re.sub(r"/\*\*$", "", p)
    if p.startswith(".github/"):
        name = name.rsplit("/", 1)[-1]
    if name not in row[0]:
        print(f"the row for release.yml does not name {name}, which starts a release run")
PY
}
check "the release row names every path that starts a push run" "" "$(paths_missing "$HERE/CONTRIBUTING.md" "$HERE/.github/workflows/release.yml")"
sed 's/ or `reusable-build.yml`//' "$HERE/CONTRIBUTING.md" > "$WORK/narrow.md"
check "a row that leaves one out names it" "the row for release.yml does not name reusable-build.yml, which starts a release run" \
	"$(paths_missing "$WORK/narrow.md" "$HERE/.github/workflows/release.yml")"

# --- commands run scripts through an interpreter ---------------------------------
# bare <guide>: the lines of a fenced block that start a repository script by its path.
bare() { sed -n '/^```/,/^```/p' "$1" | grep -E '^(\./)?scripts/[A-Za-z0-9_./-]+\.sh' ; true; }
check "no command in the guide runs a script by its execute bit" "" "$(bare "$HERE/CONTRIBUTING.md")"
printf '```sh\nscripts/quality/x.sh\nbash scripts/quality/y.sh\n```\n' > "$WORK/guide.md"
check "one that does is named, and one through bash is not" "scripts/quality/x.sh" "$(bare "$WORK/guide.md")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
