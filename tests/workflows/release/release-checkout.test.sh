#!/usr/bin/env bash
#
# The checkout of the jobs of release.yml that sign and publish. CodeQL (actions/cache-poisoning/poisonable-step) reads a
# checkout of a ref taken from an output as untrusted code in a job that uploads an artifact, and the jobs that sign and
# publish are the ones where that matters. The ref is gone: the checkout is the commit of the event, which is the commit the
# plan resolved (it refuses a checkout at any other), and the step right after it refuses a HEAD that is not that commit, before
# any code of the repository runs. Read from the workflow, with the copies that break it and the step run for real.
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
# shellcheck source=tests/lib/release-workflow.sh
. "$HERE/tests/lib/release-workflow.sh"

check "no checkout names a ref, and sign and publish compare HEAD with the plan's commit right after it" "" "$(violations checkout)"
BAD="$WORK/bad"
# A copy of the workflows with the first checkout (the one of sign) given a ref, and one with the check after it dropped.
breakit() { # <what> -> the copy in $BAD
	rm -rf "$BAD"; mkdir -p "$BAD"; cp "$HERE"/.github/workflows/*.yml "$BAD/"
	python3 - "$BAD/release.yml" "$1" <<'PY'
import sys
path, what = sys.argv[1:3]
s = open(path).read()
checkout = "        with: { persist-credentials: false }\n"
check = "      - name: Check the checkout is the commit the plan resolved\n"
assert s.count(checkout) == 2 and s.count(check) == 2
if what == "ref":
    s = s.replace(checkout, '        with: { ref: "${{ needs.plan.outputs.sha }}", persist-credentials: false }\n', 1)
else:
    i = s.index(check)
    j = s.index("\n", s.index("run:", i)) + 1
    s = s[:i] + s[j:]
open(path, "w").write(s)
PY
}
breakit ref
check "a checkout that is given a ref is named" "sign checks out a ref" "$(violations checkout "$BAD" | grep 'checks out a ref')"
breakit drop
check "a job whose step after the checkout does not compare HEAD is named" "sign: the step after the checkout does not refuse a HEAD that is not the commit the plan resolved" \
	"$(violations checkout "$BAD" | grep 'the step after the checkout' | head -n 1)"

# The step itself, run in a repository: it passes at the commit the plan resolved, and refuses at another, saying so.
R="$WORK/step"
if step release.yml sign "name=Check the checkout is the commit the plan resolved" "$R"; then
	check "the step's run block has no expression in it" 0 "$(grep -c '\${{' "$R/run.sh")"
	git init -q "$WORK/repo"
	git -C "$WORK/repo" -c user.email=a@b -c user.name=a commit -q --allow-empty -m one
	head="$(git -C "$WORK/repo" rev-parse HEAD)"
	git -C "$WORK/repo" -c user.email=a@b -c user.name=a commit -q --allow-empty -m two
	now="$(git -C "$WORK/repo" rev-parse HEAD)"
	run_step() { (cd "$WORK/repo" && SHA="$1" bash -e -o pipefail "$R/run.sh" > "$WORK/out" 2>&1); rc=$?; }
	run_step "$now"
	check "at the commit the plan resolved the step passes" 0 "$rc"
	run_step "$head"
	check "at another commit it fails and says so" "1 1" "$rc $(grep -c 'the checkout is not at' "$WORK/out")"
	run_step ""
	check "with no commit from the plan it fails too" 1 "$rc"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
