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

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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
	# A repository with the base commit, which holds the script as the base branch has
	# it: it records what it was asked and refuses when VERDICT says no. The head's copy
	# in the tree says ok to anything.
	W="$S/ws"; mkdir -p "$W/scripts/quality" "$S/rt"
	g() { git -C "$W" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false "$@"; }
	g init -q
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$#" "$@" > "$ASKED"\n[ "${VERDICT:-ok}" = ok ] || { echo "the base script refuses"; exit 1; }\necho "the base script says ok"\n' > "$W/scripts/quality/$script"
	g add -A; g commit -q -m base
	base_sha="$(g rev-parse HEAD)"
	printf '#!/usr/bin/env bash\necho "the head script says ok"\nexit 0\n' > "$W/scripts/quality/$script"
	g add -A; g commit -q -m "a change that rewrote the script"
	run_step "$S" "$W" ASKED="$S/asked" RUNNER_TEMP="$S/rt" BASE="$base_sha" HEAD=the-head
	check "$job: the step passes when the script of the base does" 0 "$rc"
	check "$job: $script is given the base and the head, and nothing else" "2 $base_sha the-head" "$(paste -sd' ' "$S/asked")"
	check "$job: and the script that ran is the base's" "1 0" "$(says 'the base script says ok') $(says 'the head script says ok')"
	run_step "$S" "$W" ASKED="$S/asked" RUNNER_TEMP="$S/rt" BASE="$base_sha" HEAD=the-head VERDICT=no
	check "$job: a base script that refuses stops the step, whatever the head's copy says" "1 1 0" \
		"$rc $(says 'the base script refuses') $(says 'the head script says ok')"
	# The base has no copy yet: the commit that introduces the script is judged by it.
	g checkout -q --orphan fresh; g rm -rq --cached . ; g commit -q --allow-empty -m "a base without the script"
	rm -f "$S"/rt/*
	run_step "$S" "$W" ASKED="$S/asked" RUNNER_TEMP="$S/rt" BASE="$(g rev-parse HEAD)" HEAD=the-head
	check "$job: a base that has no copy of the script falls back to the tree's" "0 1" "$rc $(says 'the head script says ok')"
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
