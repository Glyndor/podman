#!/usr/bin/env bash
#
# Tests for scripts/quality/lint/no-deprecation-notices.sh: a job of the commit
# that carries a warning about a deprecation fails the check, a notice does not,
# and a read that fails is a failure and not a pass. The answers of the API are
# planted with a `gh` that prints files, so the filters the script runs in jq are
# the ones judged, and the wait for the runs of the commit is judged too.
#
# Requires: jq, python3 with PyYAML.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/quality/lint/no-deprecation-notices.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

mkdir -p "$WORK/bin" "$WORK/api"
# A gh that answers from files named after what is asked: runs.json for the runs of
# the commit, jobs-<id>.json for the jobs of a run and annotations-<id>.json for the
# annotations of a job. A file `fail-<name>` makes that one answer fail. The runs
# are read once as they are and then as they are finished, unless `flip` is there,
# which is how a run that takes its time is planted.
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
case "$path" in
	*"/actions/runs?"*) name=runs ;;
	*"/actions/runs/"*"/jobs"*) name="jobs-${path#*/actions/runs/}"; name="${name%%/*}" ;;
	*"/check-runs/"*"/annotations"*) name="annotations-${path#*/check-runs/}"; name="${name%%/*}" ;;
	*) exit 9 ;;
esac
[ ! -e "$API_DIR/fail-$name" ] || exit 1
if [ "$name" = runs ]; then
	if [ ! -e "$API_DIR/seen" ]; then
		touch "$API_DIR/seen"
		cat "$API_DIR/runs.json"
		exit 0
	fi
	if [ -e "$API_DIR/flip" ]; then
		sed 's/"status":"in_progress"/"status":"completed"/' "$API_DIR/runs.json"
		exit 0
	fi
fi
cat "$API_DIR/$name.json"
GH
chmod +x "$WORK/bin/gh"

run() { # [sha]: the output and the status of the script against what is planted
	PATH="$WORK/bin:$PATH" API_DIR="$WORK/api" GH_TOKEN=x REPO=Glyndor/podman \
		HEAD_SHA="${1:-abc123}" WAIT_SECONDS=2 POLL_SECONDS=0 RUN_ID=999 "$SCRIPT" 2>&1
}

reset() {
	rm -f "$WORK"/api/*
	printf '{"workflow_runs":[{"id":101,"name":"tests","status":"completed","event":"pull_request"},{"id":102,"name":"build-check","status":"completed","event":"pull_request"}]}' > "$WORK/api/runs.json"
	printf '{"jobs":[{"id":11,"name":"test"},{"id":12,"name":"package builds"}]}' > "$WORK/api/jobs-101.json"
	printf '{"jobs":[{"id":21,"name":"gate"}]}' > "$WORK/api/jobs-102.json"
	printf '[]' > "$WORK/api/annotations-11.json"
	printf '[]' > "$WORK/api/annotations-12.json"
	printf '[]' > "$WORK/api/annotations-21.json"
}

note() { # <job id> <level> <message>
	printf '[{"annotation_level":"%s","message":"%s"}]' "$2" "$3" > "$WORK/api/annotations-$1.json"
}

reset
out="$(run)"; rc=$?
check "a commit with no annotation passes" "0" "$rc"
check "and says so" "1" "$(printf '%s\n' "$out" | grep -c 'carries a deprecation warning')"

reset; note 11 warning "This action is deprecated. Please update it"
out="$(run)"; rc=$?
check "a warning about a deprecated action fails" "1" "$rc"
check "and names the job" "1" "$(printf '%s\n' "$out" | grep -c "'test' carries a deprecation warning")"

reset; note 12 warning "Node.js 16 actions are deprecated. Please update the following actions to use Node.js 24"
run >/dev/null; check "a warning about a deprecated runtime fails" "1" "$?"

reset; note 21 failure "The set-output command is no longer supported"
run >/dev/null; check "a failure annotation that says it is no longer supported fails" "1" "$?"

reset; note 11 warning "actions/foo@v1 will be removed on 2027-01-01"
run >/dev/null; check "a warning that something will be removed fails" "1" "$?"

reset; note 11 warning "The following actions are forced to run on Node.js 24"
run >/dev/null; check "a runtime forced to a new Node fails" "1" "$?"

reset; note 11 warning "DEPRECATED: upper case is read as well"
run >/dev/null; check "the match ignores case" "1" "$?"

reset; note 11 notice "This command is deprecated"
run >/dev/null; check "a notice is not read, only a warning is" "0" "$?"

reset; note 11 warning "The disk is almost full"
run >/dev/null; check "a warning about something else passes" "0" "$?"

reset; touch "$WORK/api/fail-runs"
out="$(run)"; rc=$?
check "a listing that fails is a failure" "1" "$rc"
check "and says that nothing was read" "1" "$(printf '%s\n' "$out" | grep -c 'could not be listed')"

reset; touch "$WORK/api/fail-jobs-101"
out="$(run)"; rc=$?
check "a listing of the jobs that fails is a failure" "1" "$rc"
check "and names the run" "1" "$(printf '%s\n' "$out" | grep -c 'the jobs of run tests could not be listed')"

reset; touch "$WORK/api/fail-annotations-11"
out="$(run)"; rc=$?
check "an annotation read that fails is a failure" "1" "$rc"
check "and names the job it could not read" "1" "$(printf '%s\n' "$out" | grep -c "annotations of 'test' could not be read")"

reset; note 11 warning "something is deprecated"; touch "$WORK/api/fail-annotations-12"
out="$(run)"
check "a failed read does not hide the warning of another job" "1" "$(printf '%s\n' "$out" | grep -c "'test' carries")"

reset
printf '{"workflow_runs":[]}' > "$WORK/api/runs.json"
run >/dev/null; check "a commit with no run passes, there is nothing to read" "0" "$?"

reset
printf '{"workflow_runs":[{"id":101,"name":"tests","status":"queued","event":"pull_request"}]}' > "$WORK/api/runs.json"
out="$(run)"; rc=$?
check "a run that does not finish in the wait is a failure" "1" "$rc"
check "and says which run it was" "1" "$(printf '%s\n' "$out" | grep -c 'did not finish')"

reset; touch "$WORK/api/flip"
printf '{"workflow_runs":[{"id":101,"name":"tests","status":"in_progress","event":"pull_request"}]}' > "$WORK/api/runs.json"
out="$(run)"; rc=$?
check "a run that finishes while the script waits is read" "0" "$rc"
check "and it is waited for" "1" "$(printf '%s\n' "$out" | grep -c 'no job of commit abc123 carries a deprecation warning')"

reset
printf '{"workflow_runs":[{"id":999,"name":"deprecations","status":"queued","event":"pull_request"}]}' > "$WORK/api/runs.json"
printf '{"jobs":[]}' > "$WORK/api/jobs-999.json"
out="$(run)"; rc=$?
check "the run of this check is not waited for" "0" "$rc"

reset
out="$(run 'not-a-sha')"; rc=$?
check "a sha that is not a sha is refused" "1" "$rc"
check "and says so" "1" "$(printf '%s\n' "$out" | grep -c 'HEAD_SHA is not the sha of a commit')"

reset
out="$(PATH="$WORK/bin:$PATH" API_DIR="$WORK/api" GH_TOKEN=x REPO=Glyndor/podman "$SCRIPT" 2>&1)"; rc=$?
check "a missing sha is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# --- the wait outlasts the runs it waits for -----------------------------------
# short <script> <workflow dir>: one line per way the wait, or the ceiling of the
# job that waits, is too short for the other workflows of a pull request.
short() {
	python3 - "$1" "$2" <<'PY' 2>&1 || echo "the rule failed"
import glob, os, re, sys, yaml

script, root = sys.argv[1:3]
files = {os.path.basename(p): yaml.safe_load(open(p, encoding="utf-8"))
         for p in glob.glob(f"{root}/*.yml") + glob.glob(f"{root}/*.yaml")}


def ceiling(name, job):
    cfg = files[name]["jobs"][job]
    uses = cfg.get("uses", "")
    if uses:
        inner = uses.rsplit("/", 1)[1]
        return max(ceiling(inner, other) for other in files[inner]["jobs"])
    return cfg.get("timeout-minutes", 360)


def chain(name, job):
    needs = files[name]["jobs"][job].get("needs") or []
    needs = [needs] if isinstance(needs, str) else needs
    return ceiling(name, job) + max([chain(name, n) for n in needs] or [0])


longest = 0
for name, doc in files.items():
    on = doc.get("on", doc.get(True)) or {}
    if name == "deprecations.yml" or name.startswith("reusable-") or "pull_request" not in on:
        continue
    longest = max(longest, max(chain(name, job) for job in doc["jobs"]))
found = re.search(r'^wait_seconds="\$\{WAIT_SECONDS:-(\d+)\}"$', open(script, encoding="utf-8").read(), re.M)
if not found:
    print("the script holds no default wait")
    sys.exit(0)
wait = int(found.group(1))
if wait <= longest * 60:
    print(f"the wait of {wait}s is not longer than the {longest} minutes a pull request's runs may take")
if files["deprecations.yml"]["jobs"]["deprecations"]["timeout-minutes"] * 60 < wait + 300:
    print("the ceiling of the job does not leave the script five minutes after its wait")
PY
}

check "the wait outlasts the longest chain of job ceilings, and the job outlasts the wait" "" \
	"$(short "$SCRIPT" "$HERE/.github/workflows")"
sed 's/WAIT_SECONDS:-5400}/WAIT_SECONDS:-1500}/' "$SCRIPT" > "$WORK/short.sh"
check "a wait shorter than the runs it waits for is named" "1" \
	"$(short "$WORK/short.sh" "$HERE/.github/workflows" | grep -c 'is not longer than')"
cp -r "$HERE/.github/workflows" "$WORK/workflows"
sed -i 's/^    timeout-minutes: 100$/    timeout-minutes: 30/' "$WORK/workflows/deprecations.yml"
check "a job that ends before the wait does is named" "1" \
	"$(short "$SCRIPT" "$WORK/workflows" | grep -c 'five minutes after its wait')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
