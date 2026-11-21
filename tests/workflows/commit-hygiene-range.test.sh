#!/usr/bin/env bash
#
# Tests that the two jobs of .github/workflows/commit-hygiene.yml judge the whole pull
# request: every commit between the base and the head the event names, read from a
# checkout that has the history.
#
# check-commit-identity.sh and check-secrets.sh each have a suite of their own, and each
# is given a range. A narrower one (the last commit, or the head against itself) leaves
# both scripts correct and both jobs green while a credential or a personal address two
# commits back goes unread. The step is taken from the workflow and run against a fake
# of each script that records what it was asked, and the YAML is read for where the two
# ends of the range come from and for the history the checkout fetches.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

# wiring <workflow> <job>: the expressions the range is built from and the checkout.
wiring() {
	python3 - "$1" "$2" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"][sys.argv[2]]
runs = [s for s in job["steps"] if "run" in s]
uses = [s for s in job["steps"] if str(s.get("uses", "")).startswith("actions/checkout@")]
env = runs[0].get("env") or {} if len(runs) == 1 else {}
w = (uses[0].get("with") or {}) if len(uses) == 1 else {}
print(env.get("BASE"), env.get("HEAD"), w.get("fetch-depth"), w.get("ref"), sep="|")
PY
}
WANT='${{ github.event.pull_request.base.sha }}|${{ github.event.pull_request.head.sha }}|0|${{ github.event.pull_request.head.sha }}'

for pair in "commit-identity:Every commit uses a GitHub noreply address:check-commit-identity.sh" \
	"secret-scan:The change adds no credential-shaped line:check-secrets.sh"; do
	job="${pair%%:*}"; rest="${pair#*:}"; name="${rest%%:*}"; script="${rest#*:}"
	S="$WORK/$job"
	if ! step commit-hygiene.yml "$job" "name=$name" "$S"; then
		fail=$((fail + 1)); echo "FAIL  commit-hygiene.yml: cannot find the step of $job"; continue
	fi
	mkdir -p "$S/ws/scripts/quality"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$#" "$@" > "$ASKED"\n' > "$S/ws/scripts/quality/$script"
	run_step "$S" "$S/ws" ASKED="$S/asked" BASE=the-base HEAD=the-head
	check "$job: the step passes when its script does" 0 "$rc"
	check "$job: $script is given the base and the head, and nothing else" "2 the-base the-head" "$(paste -sd' ' "$S/asked")"
	check "$job: the base and the head are the event's, read from a checkout of the whole history at the head" \
		"$WANT" "$(wiring "$HERE/.github/workflows/commit-hygiene.yml" "$job")"
done

# The same reading over broken copies: each has to be seen.
BAD="$WORK/bad.yml"
sed 's/BASE: ${{ github.event.pull_request.base.sha }}/BASE: ${{ github.event.pull_request.head.sha }}/' \
	"$HERE/.github/workflows/commit-hygiene.yml" > "$BAD"
check "a base that is the head is seen" "0" "$(wiring "$BAD" secret-scan | grep -c -F -- "$WANT")"
sed 's/fetch-depth: 0/fetch-depth: 1/' "$HERE/.github/workflows/commit-hygiene.yml" > "$BAD"
check "a checkout without the history is seen" "0" "$(wiring "$BAD" secret-scan | grep -c -F -- "$WANT")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
