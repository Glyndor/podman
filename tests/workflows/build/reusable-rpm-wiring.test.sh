#!/usr/bin/env bash
#
# Tests for how the rpm packages go from the job that builds them to the job that signs, read from the workflows:
#   - the build job of reusable-package.yml uploads with no condition, before anything runs a package, under
#     rpm-<id>-<arch> for a release and rpmcheck-<id>-<arch> for a check; the test job downloads that artifact by its
#     id, failing on another digest;
#   - every leg of scripts/package/distros.txt has its output, declared by the reusable and by the job and fed by the
#     step that reports it: a leg without one would hand nothing to the job that gathers;
#   - reusable-rpm.yml calls it once for every leg, gathers only what the build jobs reported, downloads by id with the
#     digest checked, and uploads the set it hashed;
#   - release.yml asks for a release's set and package-check.yml for a check's.
# Each rule runs on the real files and on copies that break it one way each.
# shellcheck disable=SC2016 # the texts replaced in the workflows are literal expressions of Actions
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

legs="$(bash "$HERE/scripts/release/rpm/names.sh" legs | tr ' ' '_' | paste -sd' ')"

# violations [workflow dir]: one line per way the wiring does not hold; a rule that cannot run prints "rule failed"
violations() {
	python3 -I - "${1:-$HERE/.github/workflows}" "$legs" <<'PY' 2>&1 || echo "rule failed"
import os, re, sys, yaml

root, legs = sys.argv[1], sys.argv[2].split()
load = lambda name: yaml.safe_load(open(os.path.join(root, name)))
pkg, rpm = load("reusable-package.yml"), load("reusable-rpm.yml")
steps = lambda doc, job: doc["jobs"][job].get("steps") or []
uses = lambda s, a: str(s.get("uses", "")).startswith(a + "@")

# --- the leg outputs
declared = pkg[True]["workflow_call"].get("outputs") or {}
mapped = {k: v for k, v in (pkg["jobs"]["build"].get("outputs") or {}).items() if k != "artifact_id"}
for name, have in (("the reusable declares", set(declared)), ("the build job maps", set(mapped))):
    if have != set(legs):
        print(f"{name} outputs for {sorted(have)}, and the legs of distros.txt are {sorted(legs)}")
for leg in legs:
    if str((declared.get(leg) or {}).get("value", "")) != "${{ jobs.build.outputs." + leg + " }}":
        print(f"the output {leg} of the reusable is not the output {leg} of the build job")
    if str(mapped.get(leg, "")) != "${{ steps.leg.outputs." + leg + " }}":
        print(f"the output {leg} of the build job is not what the step that reports the leg wrote")

# --- the build job uploads before anything runs a package
build = steps(pkg, "build")
ups = [s for s in build if uses(s, "actions/upload-artifact")]
if len(ups) != 1:
    print(f"the build job has {len(ups)} uploads, expected 1")
else:
    up = ups[0]
    if "if" in up:
        print("the upload of the build job has a condition")
    if up.get("with", {}).get("name") != "${{ inputs.upload && 'rpm' || 'rpmcheck' }}-${{ inputs.id }}-${{ inputs.arch }}":
        print(f"the artifact of a leg is called {up.get('with', {}).get('name')}")
    if up.get("with", {}).get("path") != "${{ runner.temp }}/staged/*.rpm":
        print("the artifact is not the packages that were staged and hashed")
    if up.get("with", {}).get("if-no-files-found") != "error":
        print("an upload of nothing does not fail")
    after = build[build.index(up) + 1:]
    if [s.get("id") for s in after] != ["leg"]:
        print("something other than the report of the leg runs after the upload")
    before = [s for s in build[:build.index(up)] if "docker run" in str(s.get("run", ""))]
    if len(before) != 1 or "run-build.sh" not in before[0]["run"]:
        print("the build job starts a container other than the one that builds")
    hashed = [i for i, s in enumerate(build) if "stage-built.sh" in str(s.get("run", ""))]
    if hashed != [build.index(up) - 1]:
        print("the packages are not staged and hashed right before the upload")
if any("--privileged" in str(s.get("run", "")) for s in build):
    print("the build job runs a privileged container")

# --- the test job reads what was uploaded
downs = [s for s in steps(pkg, "test") if uses(s, "actions/download-artifact")]
if pkg["jobs"]["test"].get("needs") != "build":
    print("the test job does not wait for the build")
if len(downs) != 1 or downs[0]["with"].get("artifact-ids") != "${{ needs.build.outputs.artifact_id }}" \
        or downs[0]["with"].get("digest-mismatch") != "error" or downs[0]["with"].get("name") or downs[0]["with"].get("pattern"):
    print("the test job does not take the packages by the id the build job reported, with the digest checked")
if str(pkg["jobs"]["build"]["outputs"].get("artifact_id", "")) != "${{ steps.upload.outputs.artifact-id }}":
    print("the build job does not report the id of its upload")

# --- the gathering
call = rpm["jobs"]["package"]
if call.get("uses") != "./.github/workflows/reusable-package.yml" or str(call.get("needs")) != "list":
    print("the packages are not built by reusable-package.yml from the list of the table")
if (call.get("strategy") or {}).get("matrix", {}).get("include") != "${{ fromJSON(needs.list.outputs.matrix) }}":
    print("the packages are not built for every row of the list")
if str(call.get("with", {}).get("upload")) != "${{ inputs.upload }}":
    print("the legs are not named after what the caller asked for")
for key in ("version", "podman", "netavark", "aardvark", "podman_sha", "netavark_sha", "aardvark_sha"):
    if call.get("with", {}).get(key) != "${{ inputs." + key + " }}":
        print(f"the legs are not built from the {key} of the caller")
if not any("distros.sh matrix rpm all" in str(s.get("run", "")) for s in steps(rpm, "list")):
    print("the list is not every rpm row and architecture of the table")
gather = rpm["jobs"]["gather"]
if gather.get("needs") != "package" or "if" in gather:
    print("the gathering does not require every leg to succeed")
env = gather.get("env") or {}
if env.get("LEGS") != "${{ toJSON(needs.package.outputs) }}" or env.get("PREFIX") != "${{ inputs.upload && 'rpm' || 'rpmcheck' }}":
    print("the gathering does not read what the legs reported")
downs = [s for s in steps(rpm, "gather") if uses(s, "actions/download-artifact")]
if len(downs) != 1 or downs[0]["with"] != {"artifact-ids": "${{ steps.legs.outputs.ids }}", "merge-multiple": False,
        "digest-mismatch": "error", "path": "${{ runner.temp }}/legs"}:
    print("the gathering does not download the legs by id, each into a directory of its own, with the digest checked")
ups = [s for s in steps(rpm, "gather") if uses(s, "actions/upload-artifact")]
if len(ups) != 1 or ups[0]["with"].get("name") != "${{ env.PREFIX }}-set" or ups[0]["with"].get("path") != "${{ runner.temp }}/set/*.rpm" \
        or ups[0]["with"].get("if-no-files-found") != "error":
    print("the set is not uploaded as what was gathered")
outputs = rpm[True]["workflow_call"].get("outputs") or {}
for key, source in (("artifact_id", "steps.upload.outputs.artifact-id"), ("artifact_digest", "steps.upload.outputs.artifact-digest"), ("manifest", "steps.collect.outputs.manifest")):
    if str((outputs.get(key) or {}).get("value", "")) != "${{ jobs.gather.outputs." + key + " }}" or gather.get("outputs", {}).get(key) != "${{ " + source + " }}":
        print(f"the workflow does not report the {key} of the set")

# --- the callers
release, check = load("release.yml")["jobs"]["rpm"], load("package-check.yml")["jobs"]["package"]
# release.yml spells true as an expression, so that its text is its own in the mutation catalogue.
for label, job, want in (("release.yml", release, "${{ true && true }}"), ("package-check.yml", check, False)):
    if job.get("uses") != "./.github/workflows/reusable-rpm.yml" or job.get("with", {}).get("upload") != want:
        print(f"{label} does not gather the packages with upload {want}")
PY
}

check "the rpm packages are hashed and uploaded where they are made, every leg reports, and only what was reported is gathered" "" "$(violations)"

# broken <file> <old> <new>: a copy of the workflows with one text changed; a change that does nothing is reported
broken() {
	rm -rf "$WORK/wf"; mkdir "$WORK/wf"; cp "$HERE"/.github/workflows/*.yml "$WORK/wf/"
	python3 -I - "$WORK/wf/$1" "$2" "$3" <<'PY' || echo "FIXTURE INERT"
import sys
p, old, new = sys.argv[1:4]
t = open(p).read()
if t.count(old) < 1:
    sys.exit(f"{old!r} is not in {p}")
open(p, "w").write(t.replace(old, new, 1))
PY
}
broke() { # <desc> <file> <old> <new> <text the rule must say>
	broken "$2" "$3" "$4" >/dev/null
	check "$1" 1 "$(violations "$WORK/wf" | grep -c -F -- "$5" | sed 's/^[1-9][0-9]*$/1/')"
}

broke "a leg the reusable does not declare is named" reusable-package.yml '      leap161_aarch64: { value: "${{ jobs.build.outputs.leap161_aarch64 }}" }
' '' "the reusable declares outputs for"
broke "a leg the build job does not map is named" reusable-package.yml '      fc45_x86_64: ${{ steps.leg.outputs.fc45_x86_64 }}
' '' "the build job maps outputs for"
broke "an output fed by another leg is named" reusable-package.yml '      el9_x86_64: ${{ steps.leg.outputs.el9_x86_64 }}' '      el9_x86_64: ${{ steps.leg.outputs.el10_x86_64 }}' "the output el9_x86_64 of the build job"
broke "an upload with a condition is named" reusable-package.yml '      - id: upload
        uses:' '      - id: upload
        if: inputs.upload
        uses:' "the upload of the build job has a condition"
broke "a privileged container in the build job is named" reusable-package.yml '          docker run --rm \
            -e GIT_CONFIG_COUNT=1' '          docker run --rm --privileged \
            -e GIT_CONFIG_COUNT=1' "the build job runs a privileged container"
broke "a step that runs after the upload is named" reusable-package.yml '      - name: Report the artifact and the hashes of the leg' '      - run: "true"
      - name: Report the artifact and the hashes of the leg' "something other than the report of the leg runs after the upload"
broke "a test job that takes the packages by name is named" reusable-package.yml '          artifact-ids: ${{ needs.build.outputs.artifact_id }}' '          name: rpm-${{ inputs.id }}-${{ inputs.arch }}' "the test job does not take the packages by the id"
broke "a gathering that runs whatever the legs ended as is named" reusable-rpm.yml '    needs: package
' '    needs: package
    if: always()
' "the gathering does not require every leg to succeed"
broke "a download of the legs that merges them is named" reusable-rpm.yml '          merge-multiple: false' '          merge-multiple: true' "the gathering does not download the legs by id"
broke "a download that ignores another digest is named" reusable-rpm.yml '          digest-mismatch: error' '          digest-mismatch: warn' "the gathering does not download the legs by id"
broke "a release that gathers a check's packages is named" release.yml '      upload: ${{ true && true }}

  # The job that holds' '      upload: false

  # The job that holds' "release.yml does not gather the packages with upload"
broke "a check that gathers a release's packages is named" package-check.yml '      upload: false' '      upload: true' "package-check.yml does not gather the packages with upload False"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
