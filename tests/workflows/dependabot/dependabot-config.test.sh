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
#   registries every image the entries read comes from a registry the job can
#              reach. The hosts of the public registries are reached without a
#              declaration, and a host that is not one of them has to be declared
#              under the top-level `registries` key and named by the entry that
#              reads it: the job is refused with 403 otherwise, and the image is
#              never watched.
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
	python3 - "$1" "$HERE" <<'PY' 2>&1 || echo "rule failed"
import glob, os, re, sys, yaml

path = sys.argv[1]
root = sys.argv[2]
doc = yaml.safe_load(open(path, encoding="utf-8"))
base = os.path.basename(path)
if doc.get("version") != 2:
    print(f"{base}: the version is {doc.get('version')!r}, not 2")
updates = doc.get("updates") or []
if not updates:
    print(f"{base}: it holds no entry")
# The entry that watches the library that verifies the signature of a release.
SIGNATURE = "/.github/scripts/release"
# The hosts a job reaches without a declaration: the public registries of the
# docker ecosystem, the list of dependabot/proxy measured on 2026-11-28. A host
# that is not one of them is refused by the proxy with 403, and the images of it
# are never watched.
PUBLIC = {
    "docker.io", "index.docker.io", "registry-1.docker.io", "registry.hub.docker.com",
    "ghcr.io", "quay.io", "public.ecr.aws", "registry.access.redhat.com",
}
# The host a FROM line names. An image without a host is of the Docker Hub.
FROM = re.compile(r"^FROM\s+(?:--platform=\S+\s+)?([A-Za-z0-9.-]+)/", re.M)
# The registries the file declares, by the host each one serves.
declared = {}
for name, registry in (doc.get("registries") or {}).items():
    url = (registry or {}).get("url") or ""
    host = re.sub(r"^[a-z]+://", "", url).split("/")[0].lower()
    if host:
        declared.setdefault(host, name)

for entry in updates:
    where = entry.get("directory") or ", ".join(entry.get("directories") or [])
    labels = entry.get("labels") or []
    if not labels:
        print(f"{base}: the entry of {where} has no labels")
    if not entry.get("groups"):
        print(f"{base}: the entry of {where} has no groups")
    if where == SIGNATURE and "type:security" not in labels:
        print(f"{base}: the entry of {where}, which watches the library that verifies "
              "the signature of a release, has no type:security label")
    if entry.get("package-ecosystem") != "docker":
        continue
    named = entry.get("registries") or []
    patterns = [entry["directory"]] if entry.get("directory") else entry.get("directories") or []
    hosts = set()
    for pattern in patterns:
        for image in sorted(glob.glob(os.path.join(root, pattern.lstrip("/")))):
            dockerfile = os.path.join(image, "Dockerfile")
            if not os.path.isfile(dockerfile):
                continue
            with open(dockerfile, encoding="utf-8") as fh:
                hosts |= {host.lower() for host in FROM.findall(fh.read())}
    for host in sorted(hosts):
        if host in PUBLIC:
            continue
        name = declared.get(host)
        if not name:
            print(f"{base}: the entry of {where} reads an image of {host}, which is not declared under registries")
        elif name not in named:
            print(f"{base}: the entry of {where} reads an image of {host} but does not reference "
                  f"the registry {name} that declares it")
PY
}

check "every entry has its groups and its labels, the library of the signature is a security change, and every image comes from a registry the job reaches" "" \
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

python3 - "$HERE/.github/dependabot.yml" "$BAD/dependabot.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
doc.pop("registries", None)
yaml.safe_dump(doc, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PY
check "an image of a registry the file does not declare is named" "1" \
	"$(violations "$BAD/dependabot.yml" | grep -c 'not declared under registries')"

python3 - "$HERE/.github/dependabot.yml" "$BAD/dependabot.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for entry in doc["updates"]:
    entry.pop("registries", None)
yaml.safe_dump(doc, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PY
check "an entry that does not name the registry that declares it is named" "1" \
	"$(violations "$BAD/dependabot.yml" | grep -c 'does not reference the registry')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
