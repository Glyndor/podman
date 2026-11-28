#!/usr/bin/env bash
#
# Tests that tests.yml runs every suite and reads every script, wherever it sits. The
# two steps that find them are read from the workflow and run here against a tree made
# for the purpose, with suites and scripts at one, two and three folders deep, so a
# folder added under tests/ or scripts/ is covered without editing the workflow; and a
# file under tests/ that no step would run is named, which is what a suite named
# otherwise or put where the step does not look would be.
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

# --- the step that runs the suites ------------------------------------------------
R="$WORK/run"
if step tests.yml test name=suites "$R"; then
	check "the suites step's run block has no expression in it" 0 "$(grep -c '\${{' "$R/run.sh")"
	suite() { # <path under the workspace> <exit status>: a suite that writes down how it was run
		mkdir -p "$R/ws/$(dirname "$1")"
		printf '#!/bin/bash\necho "$0 first-on-path=${PATH%%%%:*}" >> "$LOG"\nexit %s\n' "$2" > "$R/ws/$1"
	}
	suites() { # <suite paths...>: the workspace has exactly these, all passing; sets $rc and $out
		rm -rf "$R/ws" "$R/rt"; mkdir -p "$R/ws" "$R/rt"; : > "$R/log"
		local p
		for p in "$@"; do suite "$p" 0; done
		run_step "$R" "$R/ws" LOG="$R/log" RUNNER_TEMP="$R/rt"
	}
	ran() { sed 's/ first-on-path=.*//' "$R/log" | sed 's#^.*/ws/##' | LC_ALL=C sort | paste -sd' '; }

	suites tests/a/one.test.sh tests/b/c/two.test.sh tests/d/e/f/three.test.sh tests/g.test.sh
	check "suites at every depth run, in order, and the run says how many" "0 tests/a/one.test.sh tests/b/c/two.test.sh tests/d/e/f/three.test.sh tests/g.test.sh 1" \
		"$rc $(ran) $(says '4 suites ran')"
	suites tests/a/one.test.sh tests/c/two.test.sh
	suite tests/b/broken.test.sh 1
	: > "$R/log"
	run_step "$R" "$R/ws" LOG="$R/log" RUNNER_TEMP="$R/rt"
	check "a suite that fails fails the step, and the suites after it do not run" "1 tests/a/one.test.sh tests/b/broken.test.sh" "$rc $(ran)"
	suites tests/a/plain.test.sh tests/a/release-signing-mldsa.test.sh
	check "the ML-DSA suite runs with the virtual environment first on PATH" "1 0" \
		"$(grep -c "release-signing-mldsa.test.sh first-on-path=$R/rt/mldsa-venv/bin\$" "$R/log") $(grep -c "plain.test.sh first-on-path=$R/rt/mldsa-venv/bin\$" "$R/log")"
	suites
	check "no suite at all fails the step instead of passing it" "1 1" "$rc $(says 'no suite found under tests/')"
else
	fail=$((fail + 1)); echo "FAIL  tests.yml: cannot find the step that runs the suites"
fi

# --- the step that reads every script ---------------------------------------------
C="$WORK/lint"
if step tests.yml test name=shellcheck "$C"; then
	check "the shellcheck step's run block has no expression in it" 0 "$(grep -c '\${{' "$C/run.sh")"
	mkdir -p "$C/bin"
	cat > "$C/bin/shellcheck" <<'SC'
#!/bin/sh
[ "$1" = --version ] && { echo "shellcheck fake"; exit 0; }
echo "args: $*" >> "$LOG"
for f in "$@"; do case "$f" in *bad.sh) exit 1 ;; esac; done
SC
	chmod +x "$C/bin/shellcheck"
	lint() { # <files...>: the workspace has exactly these; sets $rc and $out
		rm -rf "$C/ws"; mkdir -p "$C/ws"; : > "$C/log"
		local f
		for f in "$@"; do mkdir -p "$C/ws/$(dirname "$f")"; : > "$C/ws/$f"; done
		run_step "$C" "$C/ws" PATH="$C/bin:$PATH" LOG="$C/log"
	}
	seen() { tr ' ' '\n' < "$C/log" | grep '\.sh$' | LC_ALL=C sort | paste -sd' '; }
	lint scripts/a/one.sh scripts/b/c/two.sh tests/d/three.test.sh tests/e/f/g/four.test.sh tests/lib/helper.sh notes.txt
	check "every script and suite is read, at any depth, and nothing else" \
		"0 scripts/a/one.sh scripts/b/c/two.sh tests/d/three.test.sh tests/e/f/g/four.test.sh tests/lib/helper.sh" "$rc $(seen)"
	check "at the severity the repository holds itself to" 1 "$(grep -c -- '-S warning' "$C/log")"
	lint scripts/a/one.sh scripts/b/bad.sh
	check "a script shellcheck refuses fails the step" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
else
	fail=$((fail + 1)); echo "FAIL  tests.yml: cannot find the step that runs shellcheck"
fi

# --- nothing under tests/ is left for no step to run ------------------------------
# A file there is a suite (*.test.sh), or a helper in tests/lib that suites source, or
# data. A script that is neither runs under no step, and a name that only looks like a
# suite (x.test.bash, x_test.sh) is how a suite ends up unwired.
orphans() { # <root>: one line per file under <root>/tests that nothing runs
	local root="$1" f rel
	while IFS= read -r f; do
		rel="${f#"$root"/}"
		case "$rel" in
			*.test.sh | tests/lib/*.sh) ;;
			# The mutation sweep is a script and not a suite: mutation.yml runs it, and
			# without a line there that does, it is as orphaned as any other.
			tests/mutation/run-mutations.sh)
				grep -v '^[[:space:]]*#' "$root/.github/workflows/mutation.yml" 2>/dev/null \
					| grep -q 'bash tests/mutation/run-mutations.sh' \
					|| echo "$rel is the mutation sweep and no line of mutation.yml runs it" ;;
			*.sh) echo "$rel is a script under tests/ that is not a suite and not in tests/lib" ;;
			*.test.* | *_test.* | *-test.*) echo "$rel is named like a suite and no step runs it" ;;
		esac
	done < <(find "$root/tests" -type f | LC_ALL=C sort)
}
check "every script under tests/ is a suite or a helper, and no file is named like an unwired suite" "" "$(orphans "$HERE")"
T="$WORK/tree"
mkdir -p "$T/tests/a/b" "$T/tests/lib" "$T/tests/data"
: > "$T/tests/a/ok.test.sh"; : > "$T/tests/a/b/deep.test.sh"; : > "$T/tests/lib/helper.sh"; : > "$T/tests/data/vector.bin"
check "a tree of suites, a helper and data has none" "" "$(orphans "$T")"
: > "$T/tests/a/helper.sh"
check "a script that is neither is named" "tests/a/helper.sh is a script under tests/ that is not a suite and not in tests/lib" "$(orphans "$T")"
rm "$T/tests/a/helper.sh"; : > "$T/tests/a/b/x.test.bash"
check "a suite named with another extension is named" "tests/a/b/x.test.bash is named like a suite and no step runs it" "$(orphans "$T")"
rm "$T/tests/a/b/x.test.bash"; : > "$T/tests/a/x_test.sh"
check "and one named x_test.sh, which is a script and not a suite" "tests/a/x_test.sh is a script under tests/ that is not a suite and not in tests/lib" "$(orphans "$T")"

rm "$T/tests/a/x_test.sh"
mkdir -p "$T/tests/mutation" "$T/.github/workflows"; : > "$T/tests/mutation/run-mutations.sh"
printf '      - run: |\n          # bash tests/mutation/run-mutations.sh\n' > "$T/.github/workflows/mutation.yml"
check "the mutation sweep that mutation.yml only mentions in a comment is named" \
	"tests/mutation/run-mutations.sh is the mutation sweep and no line of mutation.yml runs it" "$(orphans "$T")"
printf '      - run: |\n          bash tests/mutation/run-mutations.sh "${selected[@]}"\n' > "$T/.github/workflows/mutation.yml"
check "and one it runs is not" "" "$(orphans "$T")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
