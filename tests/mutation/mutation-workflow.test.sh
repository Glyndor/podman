#!/usr/bin/env bash
#
# Tests for .github/workflows/mutation.yml, read from the workflow and run here. The
# sweep can be skipped by decision and a skipped job reports success, so three things
# hold it up: the gate passes only for a skip that was decided or a sweep that
# succeeded, whatever its needs ended as; the decide step runs mutation-scope.sh from
# the base commit the event names, so a pull request that rewrites the script cannot
# narrow its own sweep, and it runs every entry on anything it cannot read; and the
# sweep step hands the runner exactly the ids decided, or every id of the list for all of
# them, shared between its jobs so that each entry runs in exactly one.
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

# --- the jobs are wired to each other ----------------------------------------------
wiring() { # [workflow dir]: one line per way the jobs are not wired as the gate needs
	python3 - "${1:-$HERE/.github/workflows}/mutation.yml" <<'PY' 2>&1 || echo "rule failed"
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
gate, sweep = jobs["gate"], jobs["sweep"]
if gate.get("name") != "every catalogued guard is noticed":
    print(f"the gate is named {gate.get('name')!r}")
if str(gate.get("if", "")).strip() != "always()":
    print("the gate does not run whatever its needs ended as")
if sorted(gate.get("needs") or []) != ["decide", "sweep"]:
    print(f"the gate needs {gate.get('needs')}, not decide and sweep")
want = {"DECIDE": "needs.decide.result", "RUN": "needs.decide.outputs.run", "SWEEP": "needs.sweep.result"}
env = gate.get("env") or {}
for k, v in want.items():
    if str(env.get(k, "")).replace(" ", "") != "${{" + v + "}}":
        print(f"{k} is {env.get(k)!r}, not ${{{{ {v} }}}}")
if str(sweep.get("if", "")).replace(" ", "") != "needs.decide.outputs.run=='true'":
    print(f"the sweep runs on {sweep.get('if')!r}, not on the decision")
shares = ((sweep.get("strategy") or {}).get("matrix") or {}).get("share")
if shares != list(range(1, len(shares or []) + 1)) or not shares:
    print(f"the shares of the sweep are {shares}, not 1 to their number")
step_env = [s.get("env") or {} for s in sweep.get("steps") or [] if s.get("name") == "Every mutation is killed by a suite"]
if not step_env or step_env[0].get("SHARE") != "${{ matrix.share }}" or step_env[0].get("SHARES") != "${{ strategy.job-total }}":
    print("a job of the sweep does not take its share and their number from the matrix")
# The one run of every suite there is on main: a pull request runs only a part.
full = jobs.get("full") or {}
if full.get("uses") != "./.github/workflows/tests.yml":
    print("no job runs every suite through tests.yml")
if str(full.get("if", "")).replace(" ", "") != "github.event_name!='pull_request'":
    print(f"the full run runs on {full.get('if')!r}, not on every event but a pull request")
if full.get("needs"):
    print("the full run waits for another job")
PY
}
check "the gate runs always, needs decide and the sweep, and reads their results" "" "$(wiring)"
BAD="$WORK/bad"
mkdir -p "$BAD"
sed 's/^        share: \[1, 2, 3\]$/        share: [1, 3]/' "$HERE/.github/workflows/mutation.yml" > "$BAD/mutation.yml"
check "a share left out is named" "the shares of the sweep are [1, 3], not 1 to their number" "$(wiring "$BAD")"
sed 's/^          SHARES: \${{ strategy.job-total }}$/          SHARES: 2/' "$HERE/.github/workflows/mutation.yml" > "$BAD/mutation.yml"
check "a number of shares that is not the matrix's is named" "a job of the sweep does not take its share and their number from the matrix" "$(wiring "$BAD")"
sed 's/^    if: always()$/    if: success()/' "$HERE/.github/workflows/mutation.yml" > "$BAD/mutation.yml"
check "a gate that is skipped when a need fails is named" "the gate does not run whatever its needs ended as" "$(wiring "$BAD")"
sed 's/^      SWEEP: \${{ needs.sweep.result }}$/      SWEEP: success/' "$HERE/.github/workflows/mutation.yml" > "$BAD/mutation.yml"
check "a result that is not read from its job is named" "SWEEP is 'success', not \${{ needs.sweep.result }}" "$(wiring "$BAD")"
sed 's/^    uses: \.\/\.github\/workflows\/tests\.yml$/    uses: .\/.github\/workflows\/dco.yml/' "$HERE/.github/workflows/mutation.yml" > "$BAD/mutation.yml"
check "a full run that calls something else is named" "no job runs every suite through tests.yml" "$(wiring "$BAD")"
sed "s/^    if: github.event_name != 'pull_request'$/    if: github.event_name == 'workflow_dispatch'/" "$HERE/.github/workflows/mutation.yml" > "$BAD/mutation.yml"
check "a full run that leaves out the schedule is named" \
	"the full run runs on \"github.event_name == 'workflow_dispatch'\", not on every event but a pull request" "$(wiring "$BAD")"
sed 's/^    name: full suite$/    name: full suite\n    needs: sweep/' "$HERE/.github/workflows/mutation.yml" > "$BAD/mutation.yml"
check "a full run that a failed sweep would skip is named" "the full run waits for another job" "$(wiring "$BAD")"

# --- the gate ---------------------------------------------------------------------
G="$WORK/gate"
if step mutation.yml gate "name=Pass only when the sweep was skipped on purpose or succeeded" "$G"; then
	check "the gate step's run block has no expression in it" 0 "$(grep -c '\${{' "$G/run.sh")"
	gate() { run_step "$G" "$G" DECIDE="$1" RUN="$2" SWEEP="$3"; }
	# Every combination against the rule written out: decide succeeded, and either it
	# said no run and the sweep was skipped, or it said run and the sweep succeeded.
	results="success failure cancelled skipped"
	wrong=""; n=0
	for d in $results; do for r in true false "" maybe; do for s in $results; do
		want=1
		if [ "$d" = success ]; then
			{ [ "$r" = false ] && [ "$s" = skipped ]; } && want=0
			{ [ "$r" = true ] && [ "$s" = success ]; } && want=0
		fi
		gate "$d" "$r" "$s"
		got=0; [ "$rc" -eq 0 ] || got=1
		[ "$got" = "$want" ] || wrong="$wrong $d/${r:-empty}/$s"
		n=$((n + 1))
	done; done; done
	check "all $n combinations of decide, its answer and the sweep give the verdict of the rule" "" "${wrong# }"
	gate success false skipped
	check "skipped by decision: green, and it says so" "0 1" "$rc $(says 'the sweep was skipped on purpose')"
	gate success true skipped
	check "a sweep skipped after decide said run: red" "1 1" "$rc $(says 'decide said run=true and the sweep ended as skipped')"
	gate success false success
	check "a sweep that ran when decide said none was needed: red" "1 1" "$rc $(says 'decide said run=false and the sweep ended as success')"
	gate failure "" skipped
	check "decide failed: red, for decide" "1 1" "$rc $(says 'decide ended as failure')"
else
	fail=$((fail + 1)); echo "FAIL  mutation.yml: cannot find the gate step"
fi

# --- decide reads its script from the base commit -----------------------------------
D="$WORK/decide"
if step mutation.yml decide "name=Which entries this change can affect" "$D"; then
	check "the decide step's run block has no expression in it" 0 "$(grep -c '\${{' "$D/run.sh")"
	R="$D/repo"
	g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false "$@"; }
	mkdir -p "$R/docs"; echo a > "$R/docs/a.md"
	g init -q; g add -A; g commit -q -m "a base without the script"
	noscript="$(g rev-parse HEAD)"
	mkdir -p "$R/scripts/quality"
	# The base's script answers from $ANSWER, so each case says what the base decides.
	printf '#!/usr/bin/env bash\n[ "$EVENT" = pull_request ] || { echo all; exit 0; }\nprintf "%%b" "$ANSWER"\n' > "$R/scripts/quality/mutation-scope.sh"
	g add -A; g commit -q -m base
	base="$(g rev-parse HEAD)"
	printf '#!/usr/bin/env bash\necho\n' > "$R/scripts/quality/mutation-scope.sh"
	g commit -q -am "a pull request that tells the decision to run nothing"
	rewrite="$(g rev-parse HEAD)"
	decide() { # <event> <base> [ANSWER=...]: the pull request is checked out
		g checkout -q "$rewrite"; rm -rf "$D/rt"; mkdir "$D/rt"; : > "$D/out"
		run_step "$D" "$R" RUNNER_TEMP="$D/rt" GITHUB_OUTPUT="$D/out" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
			EVENT="$1" BASE="$2" HEAD="$rewrite" "${@:3}"
		answer="$(sed -n 's/^run=//p' "$D/out") $(sed -n 's/^ids=//p' "$D/out")"
	}
	decide pull_request "$base" ANSWER='one-entry\ntwo-entry\n'
	check "the base's decision is the one taken, whatever the pull request's script says" "0 true one-entry two-entry" "$rc $answer"
	decide pull_request "$base" ANSWER=''
	check "the base deciding nothing skips the sweep, and says so" "0 false  1" "$rc $answer $(says 'the sweep is not needed')"
	decide pull_request "$base" ANSWER='one-entry\nall\n'
	check "an answer of all runs every entry" "0 true all" "$rc $answer"
	decide pull_request "$base" ANSWER='one-entry\nNot An Id\n'
	check "a word that is not an id runs every entry" "0 true all" "$rc $answer"
	decide pull_request "$noscript"
	check "a base without the script runs every entry" "0 true all" "$rc $answer"
	decide pull_request 0000000000000000000000000000000000000000
	check "a base that cannot be read runs every entry" "0 true all" "$rc $answer"
	decide schedule ""
	check "the schedule runs every entry" "0 true all" "$rc $answer"
	decide workflow_dispatch ""
	check "and so does a dispatch" "0 true all" "$rc $answer"
else
	fail=$((fail + 1)); echo "FAIL  mutation.yml: cannot find the decide step"
fi

# --- the sweep hands the runner what was decided, shared between its jobs ----------
S="$WORK/sweep"
if step mutation.yml sweep "name=Every mutation is killed by a suite" "$S"; then
	check "the sweep step's run block has no expression in it" 0 "$(grep -c '\${{' "$S/run.sh")"
	mkdir -p "$S/ws/tests/mutation"
	# The runner: --list prints $LISTED, one id per line, and anything else is written down.
	cat > "$S/ws/tests/mutation/run-mutations.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list ]; then printf '%b' "$LISTED"; exit "${LIST_RC:-0}"; fi
echo "args:$#:$*" >> "$LOG"
exit "${FAKE_RC:-0}"
SH
	sweep() { : > "$S/log"; run_step "$S" "$S/ws" LOG="$S/log" LISTED='a\nb\nc\nd\ne\nf\ng\n' SHARE=1 SHARES=1 "$@"; }
	sweep IDS=all
	check "all, one job: the runner is given every entry of the list" "0 args:7:a b c d e f g" "$rc $(cat "$S/log")"
	sweep IDS="one-entry two-entry"
	check "two ids: the runner is given exactly those" "0 args:2:one-entry two-entry" "$rc $(cat "$S/log")"
	shares=""
	for share in 1 2 3; do
		sweep IDS=all SHARE="$share" SHARES=3
		shares+="$rc $(cat "$S/log")|"
	done
	check "three jobs: every third entry from its own, each entry in exactly one" \
		"0 args:3:a d g|0 args:2:b e|0 args:2:c f|" "$shares"
	sweep IDS="one-entry two-entry" SHARE=2 SHARES=3
	check "decided ids are shared the same way" "0 args:1:two-entry" "$rc $(cat "$S/log")"
	sweep IDS="one-entry two-entry" SHARE=3 SHARES=3
	check "a share with no entry runs nothing, and not every entry" "0  1" "$rc $(cat "$S/log") $(says 'no entry falls to share 3 of 3')"
	for bad in "SHARE=0" "SHARE=4" "SHARE=" "SHARE=x" "SHARES=0" "SHARES="; do
		sweep IDS=all SHARES=3 "$bad"
		check "'$bad' is not a share: nothing runs" "1  1" "$rc $(cat "$S/log") $(says 'is not a share of the sweep')"
	done
	sweep IDS=all LISTED=''
	check "an empty list is not an answer: nothing runs" "1  1" "$rc $(cat "$S/log") $(says 'there is no entry to share')"
	sweep IDS=all LIST_RC=3
	check "a list that cannot be read stops the step" "3 " "$rc $(cat "$S/log")"
	sweep IDS=all FAKE_RC=1
	check "a survivor in the sweep fails the step" 1 "$rc"
else
	fail=$((fail + 1)); echo "FAIL  mutation.yml: cannot find the sweep step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
