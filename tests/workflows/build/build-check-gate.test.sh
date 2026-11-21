#!/usr/bin/env bash
#
# Tests for .github/workflows/build-check.yml, the check "package builds". Its jobs
# can be skipped by decision, and a skipped job reports success, so three things
# hold the gate up and each is run here from the workflow: the gate step passes only
# for a skip that was decided or a build that succeeded, whatever its needs ended as;
# the decide step reads decide-build.sh from the base commit the event names, so a
# pull request that rewrites the script cannot skip its own build, and it lists a moved
# file under its old path too, so moving a build script out cannot skip it either; and the plan step
# refuses an upstream tag that is not annotated. The decide step runs against a
# throwaway repository with the real decide-build.sh in it.
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

# --- the gate reads every result of its needs -------------------------------------
# The step's inputs are the job's env, and the job must run whatever its needs did.
wiring() { # [workflow dir]: one line per way the gate job is not wired to its needs
	python3 - "${1:-$HERE/.github/workflows}/build-check.yml" <<'PY' 2>&1 || echo "rule failed"
import sys, yaml
gate = yaml.safe_load(open(sys.argv[1]))["jobs"]["gate"]
if gate.get("name") != "package builds":
    print(f"the gate is named {gate.get('name')!r}, and the ruleset requires 'package builds'")
if str(gate.get("if", "")).strip() != "always()":
    print("the gate does not run whatever its needs ended as")
if sorted(gate.get("needs") or []) != ["build", "decide", "plan"]:
    print(f"the gate needs {gate.get('needs')}, not decide, plan and build")
want = {"DECIDE": "needs.decide.result", "WANTED": "needs.decide.outputs.build",
        "PLAN": "needs.plan.result", "BUILD": "needs.build.result"}
env = gate.get("env") or {}
for k, v in want.items():
    if str(env.get(k, "")).replace(" ", "") != "${{" + v + "}}":
        print(f"{k} is {env.get(k)!r}, not ${{{{ {v} }}}}")
PY
}
check "the gate runs always, needs decide, plan and build, and reads their results" "" "$(wiring)"
BAD="$WORK/bad"
mkdir -p "$BAD"
sed 's/^    if: always()$/    if: success()/' "$HERE/.github/workflows/build-check.yml" > "$BAD/build-check.yml"
check "a gate that is skipped when a need fails is named" "the gate does not run whatever its needs ended as" "$(wiring "$BAD")"
sed 's/^      BUILD: \${{ needs.build.result }}$/      BUILD: success/' "$HERE/.github/workflows/build-check.yml" > "$BAD/build-check.yml"
check "a result that is not read from its job is named" "BUILD is 'success', not \${{ needs.build.result }}" "$(wiring "$BAD")"

G="$WORK/gate"
if step build-check.yml gate "name=Pass only when the build was skipped on purpose or succeeded" "$G"; then
	check "the gate step's run block has no expression in it" 0 "$(grep -c '\${{' "$G/run.sh")"
	gate() { run_step "$G" "$G" DECIDE="$1" WANTED="$2" PLAN="$3" BUILD="$4"; }
	# Every combination, against the rule written out: decide succeeded, and either it
	# said no build and the build was skipped, or it said build and plan and build
	# succeeded. Anything else is red.
	results="success failure cancelled skipped"
	wrong=""; n=0
	for d in $results; do for w in true false "" maybe; do for p in $results; do for b in $results; do
		want=1
		if [ "$d" = success ]; then
			if [ "$w" = false ] && [ "$b" = skipped ]; then want=0; fi
			if [ "$w" = true ] && [ "$p" = success ] && [ "$b" = success ]; then want=0; fi
		fi
		gate "$d" "$w" "$p" "$b"
		got=0; [ "$rc" -eq 0 ] || got=1
		[ "$got" = "$want" ] || wrong="$wrong $d/${w:-empty}/$p/$b"
		n=$((n + 1))
	done; done; done; done
	check "all $n combinations of decide, its answer, plan and build give the verdict of the rule" "" "${wrong# }"
	gate success false skipped skipped
	check "skipped by decision: green, and it says so" "0 1" "$rc $(says 'the build was skipped on purpose')"
	gate success true success success
	check "built: green" "0 1" "$rc $(says 'plan and build succeeded')"
	gate success true success skipped
	check "a build skipped after decide said build: red, for the build" "1 1" "$rc $(says 'build ended as skipped')"
	gate success true success cancelled
	check "a build cancelled: red, for the build" "1 1" "$rc $(says 'build ended as cancelled')"
	gate success true skipped skipped
	check "a plan that did not run: red, for the plan" "1 1" "$rc $(says 'plan ended as skipped, so nothing was built')"
	gate success false skipped success
	check "a build that ran when decide said none was needed: red" "1 1" "$rc $(says 'decide said no build is needed but build ended as success')"
	gate failure "" skipped skipped
	check "decide failed, and every job after it was skipped: red, for decide" "1 1" "$rc $(says 'decide ended as failure')"
	gate success "" skipped skipped
	check "decide gave no answer: red, not read as no build" "1 1" "$rc $(says "decide gave no usable answer ('')")"
else
	fail=$((fail + 1)); echo "FAIL  build-check.yml: cannot find the gate step"
fi

# --- decide reads its script from the base commit --------------------------------
D="$WORK/decide"
if step build-check.yml decide "name=Does this change touch what the package is built from" "$D"; then
	check "the decide step's run block has no expression in it" 0 "$(grep -c '\${{' "$D/run.sh")"
	R="$D/repo"
	g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false "$@"; }
	mkdir -p "$R"; g init -q
	mkdir -p "$R/docs" "$R/scripts/build"
	echo a > "$R/docs/a.md"; echo b > "$R/scripts/build/b"
	g add -A; g commit -q -m "a base without the gate script"
	nogate="$(g rev-parse HEAD)"
	mkdir -p "$R/scripts/ci"; cp "$HERE/scripts/ci/decide-build.sh" "$R/scripts/ci/"
	g add -A; g commit -q -m base
	base="$(g rev-parse HEAD)"
	echo changed > "$R/docs/a.md"; g commit -q -am "docs only"
	docs="$(g rev-parse HEAD)"
	g checkout -q "$base"
	printf '#!/usr/bin/env bash\necho false\n' > "$R/scripts/ci/decide-build.sh"
	echo changed > "$R/scripts/build/b"
	g commit -q -am "a build change that also tells the gate to skip it"
	rewrite="$(g rev-parse HEAD)"
	# A build script moved out of the build: with rename detection git names only the
	# new path, docs/b, and the decision would be to skip.
	g checkout -q "$base"
	g mv scripts/build/b docs/b
	g commit -q -m "a build script moved into docs/"
	moved="$(g rev-parse HEAD)"
	check "the fixture is a rename git detects" "R100 scripts/build/b docs/b" \
		"$(g diff --find-renames --name-status "$base" "$moved" | paste -sd' ' | tr '\t' ' ')"
	decide() { # <base> <head>: the repository is checked out at <head>, as the pull request is
		g checkout -q "$2"; rm -rf "$D/rt"; mkdir "$D/rt"; : > "$D/out"
		run_step "$D" "$R" RUNNER_TEMP="$D/rt" GITHUB_OUTPUT="$D/out" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 BASE="$1" HEAD="$2"
		answer="$(sed -n 's/^build=//p' "$D/out")"
	}
	decide "$base" "$docs"
	check "a pull request that changes only docs skips the build" "0 false" "$rc $answer"
	decide "$base" "$rewrite"
	check "one that rewrites the gate script to skip still builds: the script is the base's" "0 true" "$rc $answer"
	decide "$base" "$moved"
	check "one that moves a build script out of scripts/build still builds: the old path is listed" "0 true" "$rc $answer"
	decide "$nogate" "$docs"
	check "a base that does not have the script builds" "0 true" "$rc $answer"
	decide 0000000000000000000000000000000000000000 "$docs"
	check "a base that cannot be read builds" "0 true" "$rc $answer"
else
	fail=$((fail + 1)); echo "FAIL  build-check.yml: cannot find the decide step"
fi

# --- the plan refuses a tag that is not annotated --------------------------------
# latest-stable.sh answers a fixed tag per component; git ls-remote answers the commit
# of a tag's peeled ref, which a component named in $LIGHTWEIGHT does not have.
P="$WORK/plan"
if step build-check.yml plan "name=Resolve the newest stable upstream tags" "$P"; then
	check "the plan step's run block has no expression in it" 0 "$(grep -c '\${{' "$P/run.sh")"
	mkdir -p "$P/ws/scripts/upstream" "$P/bin"
	printf '#!/bin/sh\ncase "$1" in */podman.git) echo v6.2.0 ;; *) echo v2.1.0 ;; esac\n' > "$P/ws/scripts/upstream/latest-stable.sh"
	cat > "$P/bin/git" <<'GIT'
#!/usr/bin/env bash
[ "$1" = ls-remote ] || exit 1
c="${2##*/}"; c="${c%.git}"
case " ${LIGHTWEIGHT:-} " in *" $c "*) exit 0 ;; esac
printf 'c0ffee-%s\t%s\n' "$c" "$3"
GIT
	chmod +x "$P/bin/git"
	plan() { : > "$P/out"; run_step "$P" "$P/ws" PATH="$P/bin:$PATH" GITHUB_OUTPUT="$P/out" "$@"; }
	plan
	check "annotated tags: each component's commit is handed on" "0 c0ffee-podman 6.2.0 c0ffee-netavark c0ffee-aardvark-dns" \
		"$rc $(sed -n 's/^\(podman\|netavark\|aardvark\)_sha=//p; s/^version=//p' "$P/out" | paste -sd' ')"
	plan LIGHTWEIGHT=netavark
	check "a tag that is not annotated stops the plan, and says which" "1 1" "$rc $(says 'netavark v2.1.0 is not an annotated tag upstream')"
	check "and no commit is handed on for it" 0 "$(grep -c '^netavark_sha=' "$P/out")"
else
	fail=$((fail + 1)); echo "FAIL  build-check.yml: cannot find the plan step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
