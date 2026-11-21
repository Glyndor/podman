#!/usr/bin/env bash
#
# Tests for the health job of .github/workflows/keyring-watch.yml: the alarm that says
# too few of the Podman signing keys will still be valid. keyring-health.sh has its own
# suite; what nothing else reads is the number the workflow hands it and what the
# alarm does with the answer. The step that runs the script is read from the workflow
# and run here against throwaway keys, so lowering the minimum in the workflow turns a
# case red; the step that opens the issue runs with a gh that records what it was asked.
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

# --- the step that asks the script ------------------------------------------------
# Three throwaway keys: one valid past the sixty days, one that never expires, one
# that expires inside them. With all three two are valid; without the first, one.
mkdir "$WORK/keys"
newkey() { # <name> <expiry>
	local home="$WORK/gh-$1"
	mkdir -m700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' --quick-gen-key "$1 <$1@x>" ed25519 sign "$2" 2>/dev/null
	GNUPGHOME="$home" gpg --batch --armor --export "$1@x" > "$WORK/keys/$1.asc"
}
newkey long 400d
newkey forever 0
newkey soon 10d

H="$WORK/health"
if step keyring-watch.yml health "name=At least two keys are valid for the next sixty days" "$H"; then
	check "the health step's run block has no expression in it" 0 "$(grep -c '\${{' "$H/run.sh")"
	ask() { # <key files...>: the keyring is exactly these keys; sets $rc, $out and $code
		rm -rf "$H/ws" "$H/rt" "$H/output"; mkdir -p "$H/ws/scripts/upstream" "$H/ws/keyring/podman" "$H/rt"
		cp "$HERE/scripts/upstream/keyring-health.sh" "$H/ws/scripts/upstream/"
		local k
		for k in "$@"; do cp "$WORK/keys/$k.asc" "$H/ws/keyring/podman/"; done
		: > "$H/output"
		run_step "$H" "$H/ws" RUNNER_TEMP="$H/rt" GITHUB_OUTPUT="$H/output"
		code="$(sed -n 's/^code=//p' "$H/output")"
	}
	ask long forever soon
	check "two valid keys out of three: the job reports success" "0 0" "$rc $code"
	check "and says how many are valid and how many are needed" 1 "$(says '2 key(s) still valid 60 days from now, 2 needed')"
	ask long soon
	check "one valid key out of two: the job reports failure" "0 1" "$rc $code"
	check "and says how many are valid and how many are needed" 1 "$(says '1 key(s) still valid 60 days from now, 2 needed')"
	check "and the key that expires inside the window is the one not counted" 1 "$(says 'not valid in the window')"
	ask
	check "no keys at all is not read as success" "0 2" "$rc $code"
else
	fail=$((fail + 1)); echo "FAIL  keyring-watch.yml: cannot find the step that asks for the key count"
fi

# --- the step that opens the issue ------------------------------------------------
I="$WORK/issue"
if step keyring-watch.yml health "name=Open an issue when they are not" "$I"; then
	check "the alarm step's run block has no expression in it" 0 "$(grep -c '\${{' "$I/run.sh")"
	check "it runs on any code but 0" "steps.health.outputs.code != '0'" "$(python3 - "$HERE/.github/workflows/keyring-watch.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["health"]["steps"]
print([s for s in steps if s.get("name") == "Open an issue when they are not"][0]["if"])
PY
)"
	mkdir -p "$I/bin"
	cat > "$I/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"issue list") printf '%s\n' "${OPEN_ISSUE:-}" ;;
	"issue create")
		while [ $# -gt 0 ]; do
			case "$1" in --title) echo "title: $2" >> "$LOG" ;; --label) echo "label: $2" >> "$LOG" ;; esac
			shift
		done ;;
	*) exit 1 ;;
esac
GH
	chmod +x "$I/bin/gh"
	alarm() { # <code> [open issue number]: sets $rc, and $I/log holds what gh was asked to create
		rm -rf "$I/rt"; mkdir "$I/rt"; : > "$I/log"
		echo "1 key(s) still valid 60 days from now, 2 needed" > "$I/rt/health.txt"
		run_step "$I" "$I" PATH="$I/bin:$PATH" RUNNER_TEMP="$I/rt" LOG="$I/log" CODE="$1" OPEN_ISSUE="${2:-}" GH_TOKEN=a-token GH_REPO=owner/repo
	}
	alarm 1
	check "too few keys: an issue is opened, and the run still fails" "1 1" "$rc $(grep -c '^title: Fewer than two Podman signing keys will be valid$' "$I/log")"
	check "and it is a security issue of the highest priority" "type:security prio:P1" "$(sed -n 's/^label: \(type\|prio\):/\1:/p' "$I/log" | grep -E 'type:security|prio:P1' | paste -sd' ')"
	alarm 2
	check "a keyring that cannot be read: an issue that says so, not the one about too few keys" "1 1 0" \
		"$rc $(grep -c '^title: The Podman signing keyring could not be read$' "$I/log") $(grep -c 'Fewer than two' "$I/log")"
	alarm 1 12
	check "an issue already open is not opened twice, and the run still fails" "1 0" "$rc $(grep -c '^title:' "$I/log")"
else
	fail=$((fail + 1)); echo "FAIL  keyring-watch.yml: cannot find the step that opens the issue"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
