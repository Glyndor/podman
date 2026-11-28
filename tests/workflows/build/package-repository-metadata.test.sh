#!/usr/bin/env bash
#
# The repository the proof of a package installs from is made once, before the proof, in the container the package was
# built in, because the images the proof also runs on do not all have createrepo_c (Red Hat's UBI has neither it nor
# EPEL). Read from reusable-package.yml:
#   - it is made in the job that tests, after the packages are downloaded and before the proof;
#   - it runs make-repo.sh in the image of the distribution, reading the packages read-only and writing only the metadata;
#   - the metadata is put beside the packages the proof mounts, so every image reads the same repository;
#   - the proof does not make a repository of its own with a tool from the repositories of its image.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

rules() { # <workflow file>: one line per violation
	python3 - "$1" 2>&1 <<'PY' || echo "rule failed"
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["test"]["steps"]
names = [s.get("name", "") for s in steps]
def find(prefix):
    hits = [i for i, n in enumerate(names) if n.startswith(prefix)]
    return hits[0] if len(hits) == 1 else None
download = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/download-artifact@")]
download = download[0] if len(download) == 1 else None
make = find("Make the repository the package manager will read")
proof = find("Install it with the package manager")
if None in (download, make, proof):
    print(f"steps not found: download={download} make={make} proof={proof}")
    sys.exit()
if not download < make < proof:
    print("the steps are not in the order download, make the repository, proof")
if str((steps[download].get("with") or {}).get("path", "")) != "${{ runner.temp }}/rpms":
    print("the packages are not downloaded into the directory that is read")
run = steps[make]["run"]
if 'bash /scripts/package/rpm/make-repo.sh /rpms /repo' not in run:
    print("the step does not run make-repo.sh on /rpms and /repo")
if '"package-$ID"' not in run:
    print("the step does not run in the image of the distribution")
if '-v "$RUNNER_TEMP/rpms:/rpms:ro"' not in run:
    print("the packages are not mounted read-only")
if '-v "$GITHUB_WORKSPACE/scripts:/scripts:ro"' not in run:
    print("the scripts are not mounted read-only")
if 'cp -r "$RUNNER_TEMP/repo/repodata" "$RUNNER_TEMP/rpms/"' not in run:
    print("the metadata is not put beside the packages")
if "createrepo" in steps[proof]["run"]:
    print("the proof makes a repository of its own")
if '-v "$RUNNER_TEMP/rpms:/rpms:ro"' not in steps[proof]["run"]:
    print("the proof does not read the packages and the metadata from /rpms")
PY
}
check "the repository is made after the build, before the proof, in the image of the distribution, and read by every image" "" "$(rules "$HERE/.github/workflows/reusable-package.yml")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for broken in 'make-repo.sh /rpms /repo|bash /scripts/package/rpm/make-repo.sh /rpms /repo' 'writable packages|-v "$RUNNER_TEMP/rpms:/rpms:ro" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" -v|-v "$RUNNER_TEMP/rpms:/rpms" -v "$GITHUB_WORKSPACE/scripts:/scripts:ro" -v' 'metadata not copied|cp -r "$RUNNER_TEMP/repo/repodata" "$RUNNER_TEMP/rpms/"'; do
	name="${broken%%|*}"; rest="${broken#*|}"; text="${rest%%|*}"; new=""; [ "$rest" = "$text" ] || new="${rest#*|}"
	python3 - "$HERE/.github/workflows/reusable-package.yml" "$WORK/broken.yml" "$text" "$new" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert s.count(sys.argv[3]) >= 1, sys.argv[3]
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4], 1))
PY
	check "a workflow that breaks '$name' is named" 1 "$([ -n "$(rules "$WORK/broken.yml")" ] && echo 1 || echo 0)"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
