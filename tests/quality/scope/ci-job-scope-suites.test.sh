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
# decide [<event>]: run the step that decides, on a pull request unless another
# event is named, and set $rc and $out.
decide() {
	: > "$R/output"
	run_step "$DECIDE" "$R" RUNNER_TEMP="$R/rt" GITHUB_OUTPUT="$R/output" EVENT="${1:-pull_request}"
}
# wheel: what the step said about the wheel.
wheel() { sed -n 's/^mldsa=//p' "$R/output"; }
# all: 1 when the step selected every suite of the repository it judged.
all() { [ "$(selected)" = "$(find "$R/tests" -name '*.test.sh' | grep -c .)" ] && echo 1 || echo 0; }
# in_base: commit what is pending on the base branch and start the pull request
# from there.
in_base() {
	git -C "$R" add -A; git -C "$R" commit -qm "base change"
	git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
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

# Only a pull request has a scope. Any other event runs every suite, whatever
# the commit looks like: the full run of the schedule is this step on a merge
# commit as much as on any other.
for event in schedule workflow_dispatch push merge_group; do
	repo "event-$event"; echo more >> "$R/README.md"; merge
	decide "$event"
	check "the event $event runs every suite, with the wheel" "0 1 true" "$rc $(all) $(wheel)"
done

# resolver <name> <exit status>: a base whose resolver names one suite and ends
# with that status.
resolver() {
	repo "$1"
	git -C "$R" checkout -q main
	printf '#!/usr/bin/env bash\necho tests/ci/decide-build.test.sh\nexit %s\n' "$2" > "$R/scripts/quality/scope/ci-job-scope.sh"
	in_base
	echo more >> "$R/README.md"; merge
	decide
}
resolver resolver-fails 1
check "a resolver that ends in an error runs every suite, whatever it had printed" "0 1" "$rc $(all)"
check "and the step says why" "1" \
	"$(printf '%s\n' "$out" | grep -c '^the resolver of the base commit ended in an error; every suite runs\.$')"
resolver resolver-ends-well 0
check "control: the same answer from one that ends well is the scope" "0 1" "$rc $(selected)"

# --- the step that runs the suites checks what it ran ------------------------------

# listed <name> <lines of the scope file>: the run step with that scope file.
listed() {
	repo "$1"; echo more >> "$R/README.md"; merge
	printf '%b' "$2" > "$R/rt/suite-scope.list"
	run_suites
}
listed empty-list ''
check "an empty scope file runs every suite" "0 $TOTAL 0" "$rc $(ran) $(skipped)"
listed blank-list '\n\n'
check "and so does one that names nothing" "0 $TOTAL 0" "$rc $(ran) $(skipped)"
listed one-suite 'tests/ci/decide-build.test.sh\n'
check "control: a scope file that names one suite runs that one and passes" "0 1" "$rc $(ran)"
listed unknown-suite 'tests/ci/decide-build.test.sh\ntests/ci/no-such.test.sh\n'
check "a selected suite that did not run fails the step" "1 1" \
	"$rc $(printf '%s\n' "$out" | grep -c '^::error::the suites that ran are not the suites selected$')"
check "and the step names it" "1" "$(printf '%s\n' "$out" | grep -cxF '< tests/ci/no-such.test.sh')"
repo cut-list; echo more >> "$R/README.md"; merge
printf 'tests/ci/decide-build.test.sh\ntests/ci/decide-package.test.sh\n' > "$R/rt/suite-scope.list"
# The first suite rewrites the file the step selects from: what ran is then not
# what was selected when the step began.
printf '#!/usr/bin/env bash\necho tests/ci/decide-build.test.sh > "%s"\n' "$R/rt/suite-scope.list" > "$R/tests/ci/decide-build.test.sh"
run_suites
check "a scope file cut while the suites run fails the step" "1 1" \
	"$rc $(printf '%s\n' "$out" | grep -c '^::error::the suites that ran are not the suites selected$')"

# --- the wheel is installed unless it is certain no suite needs it ------------------

repo wheelsuite; echo more >> "$R/tests/release/release-signing-mldsa.test.sh"; merge
decide
check "the wheel is installed when the suite that needs it runs" "true" "$(wheel)"
check "and the suite that needs it is among the ones that run" "1" \
	"$(grep -c '^tests/release/release-signing-mldsa.test.sh$' "$R/rt/suite-scope.list")"

# deps <name> <sed script>: a base whose dependency map is changed that way, and
# a pull request that changes the README, which runs the suite that reads it.
READER=tests/docs/verify-second-signature.test.sh
deps() {
	repo "$1"
	git -C "$R" checkout -q main
	sed -i "$2" "$R/scripts/quality/scope/suite-dependencies.txt"
	in_base
	echo more >> "$R/README.md"; merge
	decide
}
deps deps-as-it-is 's/^$//'
check "control: a selection that needs nothing installs no wheel" "0 false" "$rc $(wheel)"
deps deps-wheel "s|^$READER -\$|$READER mldsa-wheel|"
check "a selected suite that declares the wheel installs it" "0 true" "$rc $(wheel)"
deps deps-missing "\|^$READER -\$|d"
check "a selected suite the dependency map does not know installs it" "0 true" "$rc $(wheel)"
deps deps-malformed "s|^$READER -\$|$READER - extra|"
check "a selected suite with a line that cannot be read installs it" "0 true" "$rc $(wheel)"
deps deps-twice "s|^$READER -\$|$READER -\\n$READER -|"
check "a selected suite listed twice installs it" "0 true" "$rc $(wheel)"
repo deps-gone
git -C "$R" checkout -q main; git -C "$R" rm -q scripts/quality/scope/suite-dependencies.txt; in_base
echo more >> "$R/README.md"; merge
decide
check "a base without the dependency map installs it" "0 true" "$rc $(wheel)"
# The name alone installs it: the step below runs it on the wheel whatever the
# map of the base says.
repo wheel-by-name
git -C "$R" checkout -q main
sed -i 's|^\(tests/release/release-signing-mldsa.test.sh\) .*$|\1 -|' "$R/scripts/quality/scope/suite-dependencies.txt"
in_base
echo more >> "$R/tests/release/release-signing-mldsa.test.sh"; merge
decide
check "a suite named for the wheel installs it when the map says it needs nothing" "0 true" "$rc $(wheel)"
repo wheel-new
printf '#!/usr/bin/env bash\n' > "$R/tests/release/another-mldsa.test.sh"; merge
decide
check "a new suite named for the wheel installs it" "0 true" "$rc $(wheel)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
