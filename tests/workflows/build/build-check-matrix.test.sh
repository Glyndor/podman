#!/usr/bin/env bash
#
# The matrices of the workflows of this repository: a row that fails has to cut the
# run. The runners are few, and a row that waits for a verdict that already failed
# is a runner spent on nothing: the failure that cuts the run says which row does
# not enter, and the run ends there.
#
# Each matrix is read from the file it is in, the reason of the cut is read above
# the line that cuts it, and a copy that breaks it one way each is read too.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <workflow file> <job>: one line per way the matrix of a job does not
# stop the run at the first row that fails, or does not say why it does.
violations() {
	python3 - "$1" "$2" <<'PY' 2>&1 || echo "rule failed"
import os, re, sys, yaml

path, job_id = sys.argv[1:3]
doc = yaml.safe_load(open(path, encoding="utf-8"))
job = (doc.get("jobs") or {}).get(job_id)
if job is None:
    print(f"{os.path.basename(path)}: there is no job {job_id}")
    sys.exit(0)
strategy = job.get("strategy") or {}
if "matrix" not in strategy:
    print(f"{os.path.basename(path)}: the job {job_id} has no matrix")
    sys.exit(0)
if strategy.get("fail-fast") is not True:
    print(f"{os.path.basename(path)}: the matrix of {job_id} does not stop at the first row that fails")
# The reason of the cut is the comment above the line that cuts it.
above = []
for line in open(path, encoding="utf-8").read().split("\n"):
    if re.match(r"^\s*fail-fast:\s*\S+\s*$", line):
        break
    if line.strip().startswith("#"):
        above.append(line.strip().lstrip("#").strip())
    else:
        above = []
if not any("stops at the first row that fails" in text for text in above):
    print(f"{os.path.basename(path)}: the matrix of {job_id} cuts the run with no reason written above it")
PY
}

check "the matrix of the build stops at the first row that fails, and says why" "" \
	"$(violations "$HERE/.github/workflows/build-check.yml" build)"
check "the matrix of the native packages stops at the first row that fails, and says why" "" \
	"$(violations "$HERE/.github/workflows/reusable-rpm.yml" package)"

check "the matrix of the mutation sweep stops at the first share that fails, and says why" "" \
	"$(violations "$HERE/.github/workflows/mutation.yml" sweep)"

BAD="$WORK/bad"
mkdir -p "$BAD"
sed 's/^      fail-fast: true$/      fail-fast: false/' "$HERE/.github/workflows/build-check.yml" > "$BAD/build-check.yml"
check "a matrix that does not stop at the first row that fails is named" \
	"build-check.yml: the matrix of build does not stop at the first row that fails" \
	"$(violations "$BAD/build-check.yml" build)"
sed '/^      # The matrix stops at the first row that fails:/,+1d' "$HERE/.github/workflows/build-check.yml" > "$BAD/build-check.yml"
check "a matrix that cuts the run with no reason written is named" \
	"build-check.yml: the matrix of build cuts the run with no reason written above it" \
	"$(violations "$BAD/build-check.yml" build)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
