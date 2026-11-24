#!/usr/bin/env bash
#
# Tests for what decides whether the package reaches the job that signs it: the build
# job of reusable-build.yml uploads it with no condition, before any job runs it, under
# the name deb-<arch> when `inputs.upload` is true and check-<arch> when it is false; the
# test job downloads the same name; and the two workflows that call the reusable pass the
# value they need. The release passes true, because the signing job takes deb-<arch> and has
# nothing to sign without it; the pull request check passes false, so a package it builds
# can never be taken for one that is signed. The name is evaluated for each value of the
# input; the callers are read for what they hand over.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# facts [workflow dir]: what the reusable and its two callers say about the upload,
# one line per fact, and a line naming each way the reading failed.
facts() {
	python3 - "${1:-$HERE/.github/workflows}" <<'PY' 2>&1 || echo "reading failed"
import os, re, sys, yaml

def load(name):
    with open(os.path.join(sys.argv[1], name)) as fh:
        return yaml.safe_load(fh)

reusable = load("reusable-build.yml")
decl = reusable[True]["workflow_call"]["inputs"].get("upload", {})
print("input", decl.get("type"), "required" if decl.get("required") else "optional")

def name_for(step, value):
    # The two shapes the name may have: a fixed one, or `${{ inputs.upload && 'a' || 'b' }}-${{ inputs.arch }}`.
    name = str((step.get("with") or {}).get("name", ""))
    m = re.fullmatch(r"\$\{\{\s*inputs\.upload\s*&&\s*'([^']*)'\s*\|\|\s*'([^']*)'\s*\}\}(.*)", name)
    if m:
        return (m.group(1) if value == "true" else m.group(2)) + m.group(3)
    return name

ups = [s for s in reusable["jobs"]["build"]["steps"] if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
print("upload steps", len(ups))
if len(ups) == 1:
    print("upload condition:", ups[0].get("if", "none"))
    for value in ("true", "false"):
        print("upload=" + value, "artifact", name_for(ups[0], value))
    # What the test job downloads is what the build job uploaded, for both values.
    downs = [s for s in reusable["jobs"]["test"]["steps"] if str(s.get("uses", "")).startswith("actions/download-artifact@")]
    print("download steps", len(downs))
    if len(downs) == 1:
        for value in ("true", "false"):
            print("upload=" + value, "downloads", "the same" if name_for(downs[0], value) == name_for(ups[0], value) else "another")
    print("test waits for", reusable["jobs"]["test"].get("needs"))
    # The upload is the last step of the build job that touches the package, and nothing in that job runs it.
    steps = reusable["jobs"]["build"]["steps"]
    after = [str(x.get("run", "")) for x in steps[steps.index(ups[0]) + 1:]]
    print("steps of the build job after the upload:", len(after))
    # What the signer checks the package against is reported by the build job, taken before anything ran it:
    # the hash step comes before the upload, and the id, digest and hash are outputs of the job and of the call.
    names = [s.get("name") for s in steps]
    print("the package is hashed before it is uploaded:", "yes" if "Hash the package" in names and names.index("Hash the package") < steps.index(ups[0]) else "no")
    outs = reusable["jobs"]["build"].get("outputs") or {}
    print("outputs of the build job:", " ".join(f"{k}={v}" for k, v in sorted(outs.items())))
    called = reusable[True]["workflow_call"].get("outputs") or {}
    print("outputs of the call:", " ".join(f"{k}={v['value']}" for k, v in sorted(called.items())))

# The release calls it once for each architecture, with no matrix, because the outputs of the legs of a matrix
# overwrite each other; the check of a pull request has no signer and keeps its matrix.
for caller, job in (("release.yml", "build-amd64"), ("release.yml", "build-arm64"), ("build-check.yml", "build")):
    j = load(caller)["jobs"][job]
    uses = j.get("uses")
    value = (j.get("with") or {}).get("upload")
    if str(value).replace(" ", "") == "${{true}}":  # a call may spell it as an expression
        value = True
    elif str(value).replace(" ", "") == "${{false}}":
        value = False
    print(caller, job, "calls" if uses == "./.github/workflows/reusable-build.yml" else f"calls {uses}",
          "with upload", str(value).lower())
PY
}

want="input boolean required
upload steps 1
upload condition: none
upload=true artifact deb-\${{ inputs.arch }}
upload=false artifact check-\${{ inputs.arch }}
download steps 1
upload=true downloads the same
upload=false downloads the same
test waits for build
steps of the build job after the upload: 0
the package is hashed before it is uploaded: yes
outputs of the build job: artifact_digest=\${{ steps.upload.outputs.artifact-digest }} artifact_id=\${{ steps.upload.outputs.artifact-id }} sha256=\${{ steps.hash.outputs.sha256 }}
outputs of the call: artifact_digest=\${{ jobs.build.outputs.artifact_digest }} artifact_id=\${{ jobs.build.outputs.artifact_id }} sha256=\${{ jobs.build.outputs.sha256 }}
release.yml build-amd64 calls with upload true
release.yml build-arm64 calls with upload true
build-check.yml build calls with upload false"
check "the package is uploaded unconditionally, as deb for true and check for false, the test job downloads it, and each caller passes its value" "$want" "$(facts)"

# Each way the gate can be broken, on a copy of the workflows, and what is said about it.
BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
broken() { # <file> <sed expression...>: the facts of a copy with that one file changed
	rm -rf "$BAD/w"; mkdir -p "$BAD/w"; cp "$HERE"/.github/workflows/*.yml "$BAD/w/"
	local file="$1"; shift
	sed -i "$@" "$BAD/w/$file"
	set -- "$file"
	diff -q "$HERE/.github/workflows/$1" "$BAD/w/$1" >/dev/null && { echo "SABOTAGE INERT"; return; }
	facts "$BAD/w" | diff <(printf '%s\n' "$want") - | sed -n 's/^> //p'
}
check "an upload that only runs sometimes is named" "upload condition: \${{ inputs.upload }}" \
	"$(broken reusable-build.yml '0,/        uses: actions\/upload-artifact@/s//        if: ${{ inputs.upload }}\n        uses: actions\/upload-artifact@/' | grep '^upload condition')"
check "a package that is signed under the name of a check is named" "upload=true artifact check-\${{ inputs.arch }}" \
	"$(broken reusable-build.yml "0,/inputs.upload \&\& 'deb' || 'check'/s//inputs.upload \&\& 'check' || 'check'/" | grep '^upload=true artifact')"
check "a check that is uploaded under the name of the signed one is named" "upload=false artifact deb-\${{ inputs.arch }}" \
	"$(broken reusable-build.yml "0,/inputs.upload \&\& 'deb' || 'check'/s//inputs.upload \&\& 'deb' || 'deb'/" | grep '^upload=false artifact')"
check "a test job that downloads another name is named" "upload=false downloads another" \
	"$(broken reusable-build.yml "/download-artifact@/,/path:/s/'check-'/'chek-'/" | grep '^upload=false downloads')"
check "a step that runs after the upload in the build job is named" "steps of the build job after the upload: 1" \
	"$(broken reusable-build.yml '0,/if-no-files-found: error/s//if-no-files-found: error\n      - run: true/' | grep '^steps of the build job after the upload')"
check "a release that stops asking for the artifact is named, for each architecture" "release.yml build-amd64 calls with upload false
release.yml build-arm64 calls with upload false" \
	"$(broken release.yml -e 's/^      upload: true$/      upload: false/' -e 's/^      upload: \${{ true }}$/      upload: false/')"
check "a package that is hashed only after the upload is named" "the package is hashed before it is uploaded: no" \
	"$(broken reusable-build.yml 's/- name: Hash the package/- name: Hash it later/' | grep '^the package is hashed')"
check "a build job that stops reporting the id of the artifact is named" "outputs of the build job: artifact_digest=\${{ steps.upload.outputs.artifact-digest }} sha256=\${{ steps.hash.outputs.sha256 }}" \
	"$(broken reusable-build.yml '/^      artifact_id: \${{ steps.upload.outputs.artifact-id }}$/d' | grep '^outputs of the build job')"
check "a pull request check that starts uploading is named" "build-check.yml build calls with upload true" \
	"$(broken build-check.yml 's/^      upload: false$/      upload: true/')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
