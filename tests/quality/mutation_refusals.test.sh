#!/usr/bin/env bash
#
# Tests for scripts/quality/mutation_refusals.py -- the part of the mutation coverage
# check that reads a file and finds its refusals. The check's own suite
# (check-mutation-coverage.test.sh) covers it through the check; these cases call the
# module directly, so a change to what counts as a refusal fails here by name and not
# only as a different count somewhere else.
#
# Requires: python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail + 1))
	fi
}

found() { # <file name> <lines...> -> "<first>-<last>" of every refusal, 1-based, space separated
	local name="$1"; shift
	python3 - "$HERE/scripts/quality" "$name" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutation_refusals as m
lines = sys.argv[3:]
print(" ".join(f"{a + 1}-{b + 1}" for a, b in m.refusals(sys.argv[2], lines)))
PY
}

# shellcheck disable=SC2016 # the lines are literal shell code
{
check "a literal exit status is a refusal, with the condition on its line" "1-1" \
	"$(found a.sh '[ -n "$1" ] || exit 2')"
check "an exit of zero, a bare exit and a comment are not" "" \
	"$(found a.sh 'exit 0' 'exit' '# exit 1' 'echo "exit 1"')"
check "an exit that hands on a status is a refusal, and at the top level it reaches back one statement" "1-2" \
	"$(found a.sh 'rc=0' 'exit "$rc"')"
check "a helper that returns a status to its caller is not" "" \
	"$(found a.sh 'pass() { "$@"; local rc=$?; return "$rc"; }')"
check "a refusal inside a block reaches back to the header of the block" "1-3" \
	"$(found a.sh 'if [ "$1" = bad ]; then' '	echo bad >&2' '	exit 1' 'fi')"
check "a call of fail counts only where the file defines that helper" "" \
	"$(found a.sh 'fail "not a helper here"')"
check "and counts where it does" "4-4" \
	"$(found a.sh 'fail() {' '	exit 1' '}' '[ -f x ] || fail "no x"' | tr ' ' '\n' | tail -1)"
check "in a Python file a message is a refusal and a clean exit is not" "1-2" \
	"$(found a.py 'import sys' 'sys.exit("no index")' 'sys.exit(0)' 'sys.exit()')"
check "the shell exit is not read in the Python of a heredoc" "" \
	"$(found a.sh "python3 - <<'PY'" 'verdict = 0' 'exit $verdict' 'PY')"
}

echo
echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
