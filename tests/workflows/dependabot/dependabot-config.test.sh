#!/usr/bin/env bash
#
# The Dependabot configuration of this repository, read from the file itself:
#
#   groups     every entry groups its updates, so a pull request is a pull request
#              and not one per dependency: several open at once only wait on each
#              other to rebase, and each of them reruns the same checks.
#   labels     every entry carries the labels of what it is: a dependency, a build
#              or a release. The entry that watches the library which verifies the
#              signature of a release carries the label of a security change, so a
#              fix in it is not one to find out about by accident.
#
# Each rule prints the entry that breaks it, and each is run against copies that
# break it one way each.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <file>: one line per way the configuration is not what it has to be.
# A rule that cannot run prints "rule failed", so a crash is never read as none.
violations() {
	python3 - "$1" <<'PY' 2>&1 || echo "rule failed"
import os, sys, yaml

path = sys.argv[1]
doc = yaml.safe_load(open(path, encoding="utf-8"))
if doc.get("version") != 2:
    print(f"{os.path.basename(path)}: the version is {doc.get('version')!r}, not 2")
updates = doc.get("updates") or []
if not updates:
    print(f"{os.path.basename(path)}: it holds no entry")
# The entry that watches the library that verifies the signature of a release.
SIGNATURE = "/.github/scripts/release"
for entry in updates:
    where = entry.get("directory") or ", ".join(entry.get("directories") or [])
    labels = entry.get("labels") or []
    if not labels:
        print(f"{os.path.basename(path)}: the entry of {where} has no labels")
    if not entry.get("groups"):
        print(f"{os.path.basename(path)}: the entry of {where} has no groups")
    if where == SIGNATURE and "type:security" not in labels:
        print(f"{os.path.basename(path)}: the entry of {where}, which watches the library that verifies "
              "the signature of a release, has no type:security label")
PY
}

check "every entry has its groups and its labels, and the library of the signature is a security change" "" \
	"$(violations "$HERE/.github/dependabot.yml")"

BAD="$WORK/bad"
mkdir -p "$BAD"
python3 - "$HERE/.github/dependabot.yml" "$BAD/dependabot.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
yaml.safe_dump(doc, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PY
check "the fixture kept the file readable" "0" "$(violations "$BAD/dependabot.yml" | wc -l)"

python3 - "$BAD/dependabot.yml" <<'PY'
import sys, yaml
path = sys.argv[1]
doc = yaml.safe_load(open(path, encoding="utf-8"))
del doc["updates"][0]["groups"]
yaml.safe_dump(doc, open(path, "w", encoding="utf-8"), sort_keys=False)
PY
check "an entry with no groups is named" "1" "$(violations "$BAD/dependabot.yml" | grep -c 'has no groups')"

python3 - "$HERE/.github/dependabot.yml" "$BAD/dependabot.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
del doc["updates"][0]["labels"]
yaml.safe_dump(doc, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PY
check "an entry with no labels is named" "1" "$(violations "$BAD/dependabot.yml" | grep -c 'has no labels')"

python3 - "$HERE/.github/dependabot.yml" "$BAD/dependabot.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for entry in doc["updates"]:
    if entry.get("directory") == "/.github/scripts/release":
        entry["labels"] = [label for label in entry["labels"] if label != "type:security"]
yaml.safe_dump(doc, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PY
check "the library that verifies the signature without the label of a security change is named" "1" \
	"$(violations "$BAD/dependabot.yml" | grep -c 'has no type:security label')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
