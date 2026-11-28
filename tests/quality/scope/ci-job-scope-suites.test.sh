#!/usr/bin/env bash
#
# The step of .github/workflows/tests.yml that decides which suites a change can
# affect, and the step that runs them. Both are read out of the workflow the
# way GitHub reads them and run here against a repository made for the
# purpose, with the resolver and the map this repository ships, so what is
# under test is the workflow and not a copy of it.
#
# The decision itself is under test in tests/quality/scope/ci-job-scope.test.sh
# and the map in tests/quality/scope/suite-scope-map.test.sh.
#
# Requires: bash, git, python3.
# shellcheck disable=SC2154 # rc and out are set by run_step, of tests/lib/workflow-step.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

DECIDE="$WORK/decide"
RUN="$WORK/suites"
if ! step tests.yml test name="decide which suites this change can affect" "$DECIDE"; then
	echo "FAIL  tests.yml: cannot find the step that decides the scope"
	exit 1
fi
if ! step tests.yml test name=suites "$RUN"; then
	echo "FAIL  tests.yml: cannot find the step that runs the suites"
	exit 1
fi

# The suites of this repository, which is the list the job runs.
ALL_SUITES="$(cd "$HERE" && find tests -name '*.test.sh' | LC_ALL=C sort)"
TOTAL="$(printf '%s\n' "$ALL_SUITES" | grep -c .)"
check "the repository has suites to run" "1" "$([ "$TOTAL" -gt 0 ] && echo 1 || echo 0)"

# The map names every suite the job runs, so a new suite does not sit in the
# map's blind spot: an entry with no pattern is refused, and an absent entry
# would leave the suite always running.
missing=""
while IFS= read -r suite; do
	[ -n "$suite" ] || continue
	grep -qxF -- "$suite" "$HERE/scripts/quality/scope/suite-scope.txt" || missing="$missing $suite"
done <<< "$ALL_SUITES"
check "every suite the job runs has an entry in the map" "" "$missing"

# repo <name>: a repository with the suites of this repository, the resolver and
# the map, and the checkout on a branch ready to take the changes of a pull
# request.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/.github/workflows" "$R/rt"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$HERE/scripts/quality/scope/ci-job-scope.sh" "$R/scripts/quality/scope/ci-job-scope.sh"
	cp "$HERE/scripts/quality/scope/suite-scope.txt" "$R/scripts/quality/scope/suite-scope.txt"
	cp "$HERE/scripts/quality/scope/suite-dependencies.txt" "$R/scripts/quality/scope/suite-dependencies.txt"
	# The workflow of this repository, so a pull request that edits the step
	# that runs the suites is a case the decision has to answer.
	cp "$HERE/.github/workflows/tests.yml" "$R/.github/workflows/tests.yml"
	printf 'readme\n' > "$R/README.md"
	# The suites of this repository, as empty scripts: the step finds them and
	# runs them, and an empty one ends at once.
	while IFS= read -r s; do
		mkdir -p "$R/$(dirname "$s")"
		printf '#!/usr/bin/env bash\n' > "$R/$s"
	done <<< "$ALL_SUITES"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# merge: commit the pending changes and build the merge commit GitHub builds.
merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# decide: run the step that decides, and set $rc and $out.
decide() {
	run_step "$DECIDE" "$R" RUNNER_TEMP="$R/rt" GITHUB_OUTPUT="$R/output"
}
# run_suites: run the step that runs the suites, and set $rc and $out.
run_suites() {
	run_step "$RUN" "$R" RUNNER_TEMP="$R/rt"
}
# selected: the suites the step decided to run.
selected() { grep -c . "$R/rt/suite-scope.list" 2>/dev/null || echo 0; }
# ran: the suites the step ran.
ran() { printf '%s\n' "$out" | grep -c '^== '; }
# skipped: the suites the step did not run.
skipped() { printf '%s\n' "$out" | grep -c '^skip  '; }

# --- a change that touches one zone ------------------------------------------------

repo readme; echo more >> "$R/README.md"; merge
decide
check "the step that decides ends well" "0" "$rc"
check "the message is the one the resolver's design asks for" "1" \
	"$(printf '%s\n' "$out" | grep -c '^scope: [0-9][0-9]* of [0-9][0-9]* suites can be affected by this change; the rest cannot\.$')"
check "the scope is smaller than the whole" "1" \
	"$([ "$(selected)" -lt "$TOTAL" ] && echo 1 || echo 0)"
check "the scope names as many suites as the file holds" "1" \
	"$(printf '%s\n' "$out" | sed -n 's/^scope: \([0-9]*\) of .*/\1/p' | grep -qxF "$(selected)" && echo 1 || echo 0)"
check "the wheel is not installed when no suite that needs it runs" "1" \
	"$(grep -c '^mldsa=false$' "$R/output")"

run_suites
check "the step that runs the suites ends well" "0" "$rc"
check "it ran the suites the step decided to run" "1" \
	"$([ "$(ran)" = "$(selected)" ] && echo 1 || echo 0)"
check "and it did not run the others" "1" \
	"$([ "$(skipped)" = "$((TOTAL - $(selected)))" ] && echo 1 || echo 0)"
check "and it says how many suites ran" "1" \
	"$(printf '%s\n' "$out" | grep -c "^$(selected) suites ran$")"

# The suite that reads the README is among the ones that run, and the suite
# that reads CONTRIBUTING is not: the change touched the README and nothing else.
check "the suite that reads the README ran" "1" \
	"$(printf '%s\n' "$out" | grep -c '^== tests/docs/verify-second-signature.test.sh$')"
check "the suite that reads CONTRIBUTING did not" "1" \
	"$(printf '%s\n' "$out" | grep -c '^skip  tests/docs/contributing-workflows.test.sh ')"

# --- the decision fails open --------------------------------------------------------

repo noworkflow; printf 'name: x\n' > "$R/.github/workflows/other.yml"; echo more >> "$R/README.md"; merge
decide
check "a change to a workflow runs every suite" "1" \
	"$([ "$(selected)" = "$TOTAL" ] && echo 1 || echo 0)"

repo editrunner; printf '# a change to the step that runs the suites\n' >> "$R/.github/workflows/tests.yml"; merge
decide
check "a pull request that edits the step that runs the suites runs every suite" "1" \
	"$([ "$(selected)" = "$TOTAL" ] && echo 1 || echo 0)"

repo noreresolver
git -C "$R" checkout -q main; git -C "$R" rm -q scripts/quality/scope/ci-job-scope.sh
git -C "$R" commit -qm "no resolver"; git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
echo more >> "$R/README.md"; merge
decide
check "a base without the resolver runs every suite" "1" \
	"$([ "$(selected)" = "$TOTAL" ] && echo 1 || echo 0)"

repo nomap
git -C "$R" checkout -q main; git -C "$R" rm -q scripts/quality/scope/suite-scope.txt
git -C "$R" commit -qm "no map"; git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
echo more >> "$R/README.md"; merge
decide
check "a base without the map runs every suite" "1" \
	"$([ "$(selected)" = "$TOTAL" ] && echo 1 || echo 0)"

# The step that runs the suites without the file the step that decides writes
# runs every suite: a decision that could not be taken is not a shorter run.
repo noscope; echo more >> "$R/README.md"; merge
rm -f "$R/rt/suite-scope.list"
run_suites
check "the step that runs the suites ends well without the scope" "0" "$rc"
check "and it runs every suite" "1" "$([ "$(ran)" = "$TOTAL" ] && echo 1 || echo 0)"
check "and it skips none" "1" "$([ "$(skipped)" = 0 ] && echo 1 || echo 0)"

# --- the wheel is installed only when a suite that needs it runs --------------------

repo wheelsuite; echo more >> "$R/tests/release/release-signing-mldsa.test.sh"; merge
decide
check "the wheel is installed when the suite that needs it runs" "1" \
	"$(grep -c '^mldsa=true$' "$R/output")"
check "and the suite that needs it is among the ones that run" "1" \
	"$(grep -c '^tests/release/release-signing-mldsa.test.sh$' "$R/rt/suite-scope.list")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
