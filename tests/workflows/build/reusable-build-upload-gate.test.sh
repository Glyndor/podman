#!/usr/bin/env bash
#
# Tests for the one condition that decides whether the package reaches the job that
# signs it: the upload step of reusable-build.yml runs on `inputs.upload`, and the two
# workflows that call the reusable pass the value they need. The release passes true,
# because the signing job has nothing to sign without the artifact; the pull request
# check passes false, so it does not upload a package nobody asked for. The upload
# step is read from the workflow and its condition is evaluated for each value of the
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

steps = [s for s in reusable["jobs"]["build"]["steps"]
         if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
print("upload steps", len(steps))
if len(steps) == 1:
    cond = str(steps[0].get("if", "")).strip()
    m = re.fullmatch(r"\$\{\{\s*(.+?)\s*\}\}", cond)
    expr = m.group(1) if m else cond
    for value in ("true", "false"):
        # Only the input itself, or a fixed answer, can be evaluated here; any other
        # expression reads as unknown and so as a difference.
        known = {"inputs.upload": value, "true": "true", "false": "false"}
        ran = (known[expr] == "true") if expr in known else "unknown"
        print("upload=" + value, "uploads" if ran is True else "skips" if ran is False else "unknown")
    print("artifact", steps[0].get("with", {}).get("name"))

for caller, job in (("release.yml", "build"), ("build-check.yml", "build")):
    j = load(caller)["jobs"][job]
    uses = j.get("uses")
    value = (j.get("with") or {}).get("upload")
    print(caller, "calls" if uses == "./.github/workflows/reusable-build.yml" else f"calls {uses}",
          "with upload", str(value).lower())
PY
}

want="input boolean required
upload steps 1
upload=true uploads
upload=false skips
artifact deb-\${{ inputs.arch }}
release.yml calls with upload true
build-check.yml calls with upload false"
check "the step uploads for true and skips for false, and each caller passes its value" "$want" "$(facts)"

# Each way the gate can be broken, on a copy of the workflows, and what is said about it.
BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
broken() { # <file> <sed expression>: the facts of a copy with that one file changed
	rm -rf "$BAD/w"; mkdir -p "$BAD/w"; cp "$HERE"/.github/workflows/*.yml "$BAD/w/"
	sed -i "$2" "$BAD/w/$1"
	diff -q "$HERE/.github/workflows/$1" "$BAD/w/$1" >/dev/null && { echo "SABOTAGE INERT"; return; }
	facts "$BAD/w" | diff <(printf '%s\n' "$want") - | sed -n 's/^> //p'
}
check "an upload that never runs is named" "upload=true skips" \
	"$(broken reusable-build.yml 's/- if: \${{ inputs.upload }}/- if: ${{ false }}/' | grep '^upload=true')"
check "an upload that always runs is named" "upload=false uploads" \
	"$(broken reusable-build.yml 's/- if: \${{ inputs.upload }}/- if: ${{ true }}/' | grep '^upload=false')"
check "a release that stops asking for the artifact is named" "release.yml calls with upload false" \
	"$(broken release.yml 's/^      upload: true$/      upload: false/')"
check "a pull request check that starts uploading is named" "build-check.yml calls with upload true" \
	"$(broken build-check.yml 's/^      upload: false$/      upload: true/')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
