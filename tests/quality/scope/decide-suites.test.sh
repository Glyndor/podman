#!/usr/bin/env bash
#
# The script that decides which suites a change can affect:
# scripts/quality/scope/decide-suites.sh. The step of .github/workflows/tests.yml
# reads it from the BASE commit and runs it; this runs it against a repository made
# for the purpose, so what is under test is the script and not a copy of it.
#
# The step of the workflow that reads and runs it is under test in
# tests/quality/scope/ci-job-scope-suites.test.sh.
#
# Requires: bash, git.
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

# The dependency map of the base commit, when every suite it names needs nothing.
DEPS='tests/ci/one.test.sh -
tests/ci/two.test.sh -
tests/ci/three-mldsa.test.sh -
'

# repo <name> <resolver> [dependency map]: a repository with three suites, the
# script under test, a resolver and a dependency map, and the merge commit GitHub
# builds, whose first parent is the base the script reads.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/tests/ci" "$R/rt"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$HERE/scripts/quality/scope/decide-suites.sh" "$R/scripts/quality/scope/decide-suites.sh"
	printf '#!/usr/bin/env bash\n%s\n' "$2" > "$R/scripts/quality/scope/ci-job-scope.sh"
	printf '%s' "${3:-$DEPS}" > "$R/scripts/quality/scope/suite-dependencies.txt"
	printf '#!/usr/bin/env bash\n' > "$R/tests/ci/one.test.sh"
	printf '#!/usr/bin/env bash\n' > "$R/tests/ci/two.test.sh"
	printf '#!/usr/bin/env bash\n' > "$R/tests/ci/three-mldsa.test.sh"
	printf 'readme\n' > "$R/README.md"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
	echo more >> "$R/README.md"
	git -C "$R" commit -qam change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# ships <path> <content>: the pull request brings its own version of a file the
# base holds, and the merge commit is built again.
ships() {
	git -C "$R" reset -q --hard HEAD^1
	git -C "$R" checkout -q -B pr
	printf '%s' "$2" > "$R/$1"
	git -C "$R" commit -qam "the pull request's own"
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# decide [event]: run the script on a pull request unless another event is named,
# and set $rc.
decide() {
	: > "$R/rt/suite-scope.list"; : > "$R/output"
	( cd "$R" && EVENT="${1:-pull_request}" RUNNER_TEMP="$R/rt" GITHUB_OUTPUT="$R/output" \
		bash scripts/quality/scope/decide-suites.sh ) > "$R/out" 2>&1
	rc=$?
}
# selected: the suites the script decided to run.
selected() { grep -c . "$R/rt/suite-scope.list" 2>/dev/null || true; }
# wheel: what the script said about the wheel.
wheel() { sed -n 's/^mldsa=//p' "$R/output"; }

# --- the resolver of the base commit decides ----------------------------------------

# A resolver that names one suite decides that one.
repo one 'shift; echo tests/ci/one.test.sh'
decide
check "the script ends well" "0" "$rc"
check "and the resolver of the base decides" "1" "$(selected)"

# A resolver that names every suite decides every suite.
repo all 'shift; for s in "$@"; do echo "$s"; done'
decide
check "a resolver that names every suite decides every suite" "3" "$(selected)"

# The base decides, not the file the checkout holds, which is the pull request's.
repo base-wins 'shift; for s in "$@"; do echo "$s"; done'
ships scripts/quality/scope/ci-job-scope.sh '#!/usr/bin/env bash
echo tests/ci/one.test.sh
'
decide
check "the resolver of the base decides, not the one the pull request ships" "3" "$(selected)"

# The same for the map that says what each suite needs.
repo base-needs 'shift; echo tests/ci/one.test.sh' 'tests/ci/one.test.sh mldsa-wheel
'
ships scripts/quality/scope/suite-dependencies.txt 'tests/ci/one.test.sh -
'
decide
check "the dependency map of the base decides, not the one the pull request ships" "true" "$(wheel)"

# Only a pull request has a scope: the resolver would name one suite.
repo one 'shift; echo tests/ci/one.test.sh'
decide schedule
check "an event that is not a pull request decides every suite" "3" "$(selected)"

# A resolver that ends in an error decided nothing, whatever it had printed.
repo fails 'shift; echo tests/ci/one.test.sh; exit 1'
decide
check "a resolver that ends in an error decides every suite" "3" "$(selected)"
check "and the script says why" "1" \
	"$(grep -c '^the resolver of the base commit ended in an error; every suite runs\.$' "$R/out")"

# A decision that names a suite the job was not given is not a decision.
repo unknown 'shift; echo tests/ci/no-such.test.sh'
decide
check "a decision that names a suite the job was not given decides every suite" "3" "$(selected)"

# --- the wheel of the ML-DSA-65 suite -----------------------------------------------

# A suite that needs nothing does not install the wheel.
repo one 'shift; echo tests/ci/one.test.sh'
decide
check "a selected suite that needs nothing installs no wheel" "false" "$(wheel)"

# A suite named for the wheel installs it, whatever the map of the base says.
repo all 'shift; for s in "$@"; do echo "$s"; done'
decide
check "a suite named for the wheel installs it" "true" "$(wheel)"

# A suite the map declares as needing the wheel installs it too.
repo one 'shift; echo tests/ci/one.test.sh' 'tests/ci/one.test.sh mldsa-wheel
'
decide
check "a selected suite that declares the wheel installs it" "true" "$(wheel)"

# A suite the map does not know installs it: the map is the only thing that says
# a suite needs nothing.
repo one 'shift; echo tests/ci/one.test.sh' 'tests/ci/two.test.sh -
'
decide
check "a selected suite the map does not know installs it" "true" "$(wheel)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
