#!/usr/bin/env bash
#
# Tests for the alarm step of .github/workflows/keyring-watch.yml, the one that
# pushes the update branch and opens the issue when upstream's keys differ from
# keyring/podman. Its run block is read from the workflow and run here with a gh
# and a git that record what they were asked, so what is tested is what runs.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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
check "the alarm runs even when the commit step failed, and when the check of the keys did" \
	"always() && (steps.diff.outputs.differs == 'true' || steps.validate.outcome == 'failure')" "$(cat "$WORK/if.txt")"
check "the run block has no expression in it" 0 "$(grep -c '\${{' "$WORK/run.sh")"

mkdir "$WORK/bin" "$WORK/rt"
printf '+ new.asc (new key)\n' > "$WORK/rt/diff.txt"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"issue list") printf '%s\n' "${OPEN_ISSUE:-}" ;;
	"issue create")
		while [ $# -gt 0 ]; do
			[ "$1" = --body-file ] && cp "$2" "$LOG_DIR/body"
			[ "$1" = --title ] && printf '%s\n' "$2" > "$LOG_DIR/title"
			shift
		done
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
		GH_TOKEN="$token" GH_REPO=owner/repo BRANCH="$1" VALIDATE="${VALIDATE:-success}" RUN_ID=4242 \
		bash --noprofile --norc -eo pipefail "$WORK/run.sh" 2>&1)" || rc=$?
}
body_says() { grep -c -- "$1" "$WORK/log/body" 2>/dev/null; }
title_is() { [ "$(cat "$WORK/log/title" 2>/dev/null)" = "$1" ] && echo 1 || echo 0; }

# The commit step failed, so it wrote no branch: the issue still opens, says the
# branch could not be prepared, and nothing is pushed.
alarm ""
check "with no branch the issue still opens" "0 1" "$rc $(grep -c create "$WORK/log/gh")"
check "and says the branch could not be prepared" 1 "$(body_says 'could not prepare the update branch')"
check "and lists what changed" 1 "$(body_says 'new.asc (new key)')"
check "and the issue is the one about a change of keys" 1 "$(title_is 'Upstream changed the keys that sign Podman')"
check "and nothing is pushed" 0 "$(grep -c '^argv' "$WORK/log/git")"

alarm keyring/update-1
check "a branch is pushed and the issue opens" "0 1 1" "$rc $(grep -c '^argv push' "$WORK/log/git") $(grep -c create "$WORK/log/gh")"
check "and the issue links the branch" 1 "$(body_says 'ready on the branch `keyring/update-1`')"
check "the push goes to the repository's plain URL" 1 "$(grep -c '^argv push -q https://github.com/owner/repo.git keyring/update-1$' "$WORK/log/git")"
encoded="$(printf 'x-access-token:%s' "$token" | base64 -w0)"
check "the token is not in git's arguments, plain or encoded" 0 "$(grep '^argv' "$WORK/log/git" | grep -c -e "$token" -e "$encoded")"
header="$(sed -n 's/^config 1 http.https:\/\/github.com\/.extraheader AUTHORIZATION: basic //p' "$WORK/log/git")"
check "the token reaches git as a header in its environment" "x-access-token:$token" "$(printf '%s' "$header" | base64 -d 2>/dev/null)"
check "and the encoded header is masked in the log" 1 "$(printf '%s\n' "$out" | grep -c -x -F "::add-mask::$header")"
check "the token is never printed" 0 "$(printf '%s\n' "$out" | grep -c "$token")"

PUSH_RC=1 alarm keyring/update-2
check "a refused push still opens the issue" "0 1" "$rc $(grep -c create "$WORK/log/gh")"
check "and says the push did not go through" 1 "$(body_says 'could not push the update branch')"

OPEN_ISSUE=12 alarm keyring/update-3
check "an issue already open is not opened twice" "0 0" "$rc $(grep -c create "$WORK/log/gh")"

# The check of what upstream publishes failed: the comparison never ran, so there is no
# answer about a difference, and the issue is opened for the check itself. Nothing is
# pushed, because no branch was prepared. The step is told by the outcome of the check.
printf -- '- link.asc is not a plain file\n- big.asc is larger than a key should be\n' > "$WORK/rt/problems.txt"
VALIDATE=failure alarm ""
check "a check that refused what upstream publishes opens an issue" "0 1" "$rc $(grep -c create "$WORK/log/gh")"
check "about the check, not about a change of keys" "1 0" "$(title_is 'The keys upstream publishes could not be accepted') $(title_is 'Upstream changed the keys that sign Podman')"
check "and lists what the check refused" "1 1" "$(body_says 'link.asc is not a plain file') $(body_says 'big.asc is larger than a key should be')"
check "and links the run" 1 "$(body_says 'https://github.com/owner/repo/actions/runs/4242')"
check "and nothing is pushed" 0 "$(grep -c '^argv' "$WORK/log/git")"
rm -f "$WORK/rt/problems.txt"
VALIDATE=failure alarm ""
check "with no list of what was refused the issue still opens, and sends to the log" "0 1 1" "$rc $(grep -c create "$WORK/log/gh") $(body_says 'the log of the run says what')"
printf -- '- link.asc is not a plain file\n' > "$WORK/rt/problems.txt"
VALIDATE=failure OPEN_ISSUE=12 alarm ""
check "an issue about the check that is already open is not opened twice" "0 0" "$rc $(grep -c create "$WORK/log/gh")"
VALIDATE=failure PUSH_RC=1 alarm keyring/update-4
check "the check that failed leaves a branch alone: nothing is pushed even if one is named" 0 "$(grep -c '^argv' "$WORK/log/git")"
VALIDATE=skipped alarm keyring/update-5
check "a check that did not run (the fetch failed) does not make the issue about it" "1 1" "$(title_is 'Upstream changed the keys that sign Podman') $(grep -c '^argv push' "$WORK/log/git")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
