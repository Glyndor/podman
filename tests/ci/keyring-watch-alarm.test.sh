#!/usr/bin/env bash
#
# Tests for the alarm step of .github/workflows/keyring-watch.yml, the one that
# pushes the update branch and opens the issue when upstream's keys differ from
# keyring/podman. Its run block is read from the workflow and run here with a gh
# and a git that record what they were asked, so what is tested is what runs.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$HERE/.github/workflows/keyring-watch.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# Writes the run block of the step to $WORK/run.sh and its if: to $WORK/if.txt.
# Fails loudly when the step is not exactly one.
python3 - "$WF" compare "Push the branch and open an issue" "$WORK" <<'PY' || { echo "FAIL  cannot read the step"; exit 1; }
import sys, yaml
path, job, name, out = sys.argv[1:5]
with open(path) as fh:
    steps = yaml.safe_load(fh)["jobs"][job]["steps"]
hits = [s for s in steps if s.get("name") == name]
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} steps named {name!r} in job {job}")
with open(f"{out}/run.sh", "w") as fh:
    fh.write(hits[0]["run"])
with open(f"{out}/if.txt", "w") as fh:
    fh.write(str(hits[0].get("if", "")))
PY

# A failed step skips every later one unless its if: says otherwise, and this step
# is the alarm, so it has to run after a failed commit.
check "the alarm runs even when the commit step failed" \
	"always() && steps.diff.outputs.differs == 'true'" "$(cat "$WORK/if.txt")"
check "the run block has no expression in it" 0 "$(grep -c '\${{' "$WORK/run.sh")"

mkdir "$WORK/bin" "$WORK/rt"
printf '+ new.asc (new key)\n' > "$WORK/rt/diff.txt"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"issue list") printf '%s\n' "${OPEN_ISSUE:-}" ;;
	"issue create")
		while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$LOG_DIR/body"; shift; done
		echo create >> "$LOG_DIR/gh" ;;
	*) exit 1 ;;
esac
GH
cat > "$WORK/bin/git" <<'GIT'
#!/usr/bin/env bash
printf 'argv %s\n' "$*" >> "$LOG_DIR/git"
printf 'config %s %s %s\n' "${GIT_CONFIG_COUNT:-}" "${GIT_CONFIG_KEY_0:-}" "${GIT_CONFIG_VALUE_0:-}" >> "$LOG_DIR/git"
exit "${PUSH_RC:-0}"
GIT
chmod +x "$WORK/bin/gh" "$WORK/bin/git"
token="ghs_notarealtoken0123456789"

alarm() { # <branch>; sets $rc and $out, and leaves what gh and git saw in $WORK/log
	rm -rf "$WORK/log"; mkdir "$WORK/log"; : > "$WORK/log/git"; : > "$WORK/log/gh"
	rc=0
	out="$(PATH="$WORK/bin:$PATH" LOG_DIR="$WORK/log" RUNNER_TEMP="$WORK/rt" \
		GH_TOKEN="$token" GH_REPO=owner/repo BRANCH="$1" \
		bash --noprofile --norc -eo pipefail "$WORK/run.sh" 2>&1)" || rc=$?
}
body_says() { grep -c -- "$1" "$WORK/log/body" 2>/dev/null; }

# The commit step failed, so it wrote no branch: the issue still opens, says the
# branch could not be prepared, and nothing is pushed.
alarm ""
check "with no branch the issue still opens" "0 1" "$rc $(grep -c create "$WORK/log/gh")"
check "and says the branch could not be prepared" 1 "$(body_says 'could not prepare the update branch')"
check "and lists what changed" 1 "$(body_says 'new.asc (new key)')"
check "and nothing is pushed" 0 "$(grep -c '^argv' "$WORK/log/git")"

alarm keyring/update-1
check "a branch is pushed and the issue opens" "0 1 1" "$rc $(grep -c '^argv push' "$WORK/log/git") $(grep -c create "$WORK/log/gh")"
check "and the issue links the branch" 1 "$(body_says 'ready on the branch `keyring/update-1`')"

PUSH_RC=1 alarm keyring/update-2
check "a refused push still opens the issue" "0 1" "$rc $(grep -c create "$WORK/log/gh")"
check "and says the push did not go through" 1 "$(body_says 'could not push the update branch')"

OPEN_ISSUE=12 alarm keyring/update-3
check "an issue already open is not opened twice" "0 0" "$rc $(grep -c create "$WORK/log/gh")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
