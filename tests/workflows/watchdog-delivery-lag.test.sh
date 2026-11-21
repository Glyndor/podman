#!/usr/bin/env bash
#
# Tests for the delivery-lag job of .github/workflows/watchdog.yml and the alarm after
# it. delivery-lag.sh has its own suite; what nothing else read is the step that runs
# it, which has to end with the script's own verdict, and the wiring that carries that
# verdict to the alarm: a step that ended green whatever the script said would leave
# the alarm, which runs on failure(), silent for good. The step runs here with fakes of
# the scripts it calls and of git and gh, and the alarm with a gh that records.
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

# --- the verdict goes from the step to the alarm ----------------------------------
wiring() { # <workflow dir>: one line per break in the path of the verdict
	python3 - "$1/watchdog.yml" <<'PY' 2>&1 || echo "rule failed"
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
lag, alert = jobs["delivery-lag"], jobs["alert"]
if str((lag.get("outputs") or {}).get("code", "")).replace(" ", "") != "${{steps.lag.outputs.code}}":
    print("delivery-lag does not hand on the code of its step")
if alert.get("needs") not in ("delivery-lag", ["delivery-lag"]):
    print(f"the alarm needs {alert.get('needs')!r}, not delivery-lag")
if " ".join(str(alert.get("if", "")).split()) != "${{ failure() && github.event_name == 'schedule' }}":
    print(f"the alarm runs on {alert.get('if')!r}, not on a scheduled run that failed")
step = [s for s in alert.get("steps") or [] if "run" in s]
if len(step) != 1 or str((step[0].get("env") or {}).get("CODE", "")).replace(" ", "") != "${{needs.delivery-lag.outputs.code}}":
    print("the alarm does not read the code delivery-lag handed on")
PY
}
check "the code goes from the step to the job's output, and the alarm runs on a scheduled failure and reads it" "" \
	"$(wiring "$HERE/.github/workflows")"
mkdir -p "$WORK/wf"
sed "s/^    if: \${{ failure() \&\& github.event_name == 'schedule' }}\$/    if: \${{ github.event_name == 'schedule' }}/" \
	"$HERE/.github/workflows/watchdog.yml" > "$WORK/wf/watchdog.yml"
check "an alarm that no longer waits for a failure is named" \
	"the alarm runs on \"\${{ github.event_name == 'schedule' }}\", not on a scheduled run that failed" "$(wiring "$WORK/wf")"

# --- the step ends with the script's verdict --------------------------------------
L="$WORK/lag"
if step watchdog.yml delivery-lag "name=Is the newest release missing something that has waited too long" "$L"; then
	check "the step's run block has no expression in it" 0 "$(grep -c '\${{' "$L/run.sh")"
	WS="$L/ws"
	mkdir -p "$WS/scripts/upstream" "$WS/scripts/build" "$WS/scripts/monitoring" "$L/bin"
	printf '#!/bin/sh\necho v1.0.0\n' > "$WS/scripts/upstream/latest-stable.sh"
	printf '#!/bin/sh\necho r1\n' > "$WS/scripts/build/recipe-id.sh"
	printf '#!/bin/sh\nprintf "podman v1.0.0\\n" > "$1"\n' > "$WS/scripts/upstream/read-released.sh"
	# The script under test only records what it was given and answers $LAG_RC.
	printf '#!/bin/sh\necho "$*" > "$ARGS"\nexit "$LAG_RC"\n' > "$WS/scripts/monitoring/delivery-lag.sh"
	printf '#!/bin/sh\necho 2026-11-20T00:00:00Z\n' > "$L/bin/gh"
	printf '#!/bin/sh\ncase "$1" in log) echo 1763600000 ;; esac\n' > "$L/bin/git"
	chmod +x "$L/bin/gh" "$L/bin/git"
	lag() { # <rc of delivery-lag.sh>: sets $rc and $code
		rm -rf "$L/rt"; mkdir "$L/rt"; : > "$L/out"; : > "$L/args"
		run_step "$L" "$WS" PATH="$L/bin:$PATH" RUNNER_TEMP="$L/rt" GITHUB_OUTPUT="$L/out" ARGS="$L/args" \
			LAG_RC="$1" GH_TOKEN=a-token GH_REPO=owner/repo
		code="$(sed -n 's/^code=//p' "$L/out" | paste -sd' ')"
	}
	for want in 0 1 2; do
		lag "$want"
		check "delivery-lag.sh answers $want: the step ends with $want and hands on code=$want" "$want $want" "$rc $code"
	done
	lag 137
	check "a script killed before its verdict is not read as in time" "137 137" "$rc $code"
	lag 0
	check "and the script is asked with a threshold of 24 hours" 24 "$(awk '{print $NF}' "$L/args")"

	# The date of the recipe is the last commit that touched scripts/build, which only a
	# repository with a history says: here the commit of the build files is older than a
	# later one that touched something else, and the dates the step writes are read back.
	# git is the real one, except for ls-remote, which would go to the network.
	R="$L/repo"; mkdir -p "$R" "$L/realbin"
	printf '#!/bin/sh\ncase "$1" in ls-remote) exit 0 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$L/realbin/git"
	cp "$L/bin/gh" "$L/realbin/gh"; chmod +x "$L/realbin/git"
	commit() { # <epoch> <message>: everything staged, committed at that time
		GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000" \
			git -C "$R" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
			-c core.hooksPath=/dev/null commit -q -m "$2"
	}
	git -C "$R" -c init.defaultBranch=main init -q
	mkdir -p "$R/scripts/build"; cp "$WS/scripts/build/recipe-id.sh" "$R/scripts/build/"
	git -C "$R" add -A; commit 1700000000 "the build recipe"
	cp -r "$WS/scripts/upstream" "$WS/scripts/monitoring" "$R/scripts/"; echo x > "$R/notes.txt"
	git -C "$R" add -A; commit 1700500000 "something that is not the recipe"
	rm -rf "$L/rt"; mkdir "$L/rt"; : > "$L/out"; : > "$L/args"
	run_step "$L" "$R" PATH="$L/realbin:$PATH" RUNNER_TEMP="$L/rt" GITHUB_OUTPUT="$L/out" ARGS="$L/args" \
		LAG_RC=0 GH_TOKEN=a-token GH_REPO=owner/repo
	check "the recipe is dated by the last commit that touched scripts/build, not by the newest commit" \
		"0 recipe r1 1700000000" "$rc $(grep '^recipe ' "$L/rt/lag/dates")"
else
	fail=$((fail + 1)); echo "FAIL  watchdog.yml: cannot find the delivery-lag step"
fi

# --- the alarm says which of the two it is -----------------------------------------
A="$WORK/alarm"
if step watchdog.yml alert "name=Open an issue, or add to the one that is open" "$A"; then
	mkdir -p "$A/bin"
	cat > "$A/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"issue list") printf '%s\n' "${OPEN_ISSUE:-}" ;;
	"issue create" | "issue comment") echo "$2 $*" >> "$LOG" ;;
	*) exit 1 ;;
esac
GH
	chmod +x "$A/bin/gh"
	alarm() { : > "$A/log"; run_step "$A" "$A" PATH="$A/bin:$PATH" LOG="$A/log" RUN_URL=https://example.test/run/3 "$@"; }
	alarm CODE=1
	check "behind upstream: an issue that says so" "0 1" "$rc $(grep -c '^create .*--title Release pipeline is behind upstream ' "$A/log")"
	alarm CODE=2
	check "could not decide: an issue that says that instead" "0 1" \
		"$rc $(grep -c "^create .*--title The release pipeline's delivery check could not decide " "$A/log")"
	alarm CODE=1 OPEN_ISSUE=9
	check "an issue already open gets a comment, not a second issue" "0 1 0" \
		"$rc $(grep -c '^comment issue comment 9 ' "$A/log") $(grep -c '^create' "$A/log")"
else
	fail=$((fail + 1)); echo "FAIL  watchdog.yml: cannot find the alarm step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
