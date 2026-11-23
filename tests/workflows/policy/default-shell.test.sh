#!/usr/bin/env bash
#
# Tests that every workflow of the repository runs its steps with `shell: bash`, declared once for the workflow.
# Without it Actions starts `bash -e {0}`: no pipefail, so a pipeline of a step reports the status of its last
# command and a failed `git ls-remote | sort` reads as an empty answer. The helper that runs a step in the tests
# reproduces the shell the workflow gives it, so a workflow that drops the line is a weaker one in the tests too.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <dir>: the workflows of the directory that do not declare it, or declare another shell, one per line.
violations() {
	python3 - "$1" 2>&1 <<'PY' || echo "rule failed"
import glob, os, sys, yaml
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.y*ml"))):
    doc = yaml.safe_load(open(path))
    shell = ((doc.get("defaults") or {}).get("run") or {}).get("shell")
    if shell != "bash":
        print(f"{os.path.basename(path)} runs its steps with {shell!r}, not bash")
    for name, job in (doc.get("jobs") or {}).items():
        jshell = ((job.get("defaults") or {}).get("run") or {}).get("shell")
        if jshell not in (None, "bash"):
            print(f"{os.path.basename(path)}: job {name} runs its steps with {jshell!r}")
        for step in job.get("steps") or []:
            if step.get("shell") not in (None, "bash"):
                print(f"{os.path.basename(path)}: a step of {name} runs with shell {step['shell']!r}")
PY
}

check "every workflow runs its steps with shell: bash, and none of them takes another" "" "$(violations "$HERE/.github/workflows")"
mkdir "$WORK/bad"; cp "$HERE"/.github/workflows/*.yml "$WORK/bad/"
python3 - "$WORK/bad/release.yml" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
open(p, "w").write(t.replace("defaults:\n  run:\n    shell: bash\n", "", 1))
PY
check "a workflow without the default is named" "release.yml runs its steps with None, not bash" "$(violations "$WORK/bad")"
cp "$HERE/.github/workflows/release.yml" "$WORK/bad/release.yml"
sed -i '0,/^    shell: bash$/s//    shell: sh/' "$WORK/bad/build-check.yml"
check "a workflow whose default is another shell is named" "build-check.yml runs its steps with 'sh', not bash" "$(violations "$WORK/bad")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
