#!/usr/bin/env bash
#
# Tests for the step of .github/workflows/reusable-package.yml that fetches the three
# upstream sources, read from the workflow and run here under the shell GitHub uses.
#
# verify-tag.sh decides whether a tag is signed by a key of upstream, and it has its own
# suite. What this suite holds is that the build asks it: the step could take the commit
# straight from the clone and every suite of the script would still pass, while a tag
# nobody signed went on to be compiled and published. So the script here is a fake that
# records each call and answers from the case, and git is a fake that clones nothing:
# a tag the script refuses has to stop the step before anything else is fetched, and
# the commit it answers has to be the one in the clone and the one the plan resolved.
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

S="$WORK/step"
if ! step reusable-package.yml package "name=Fetch the upstream tags and verify their signatures" "$S"; then
	fail=$((fail + 1)); echo "FAIL  reusable-package.yml: cannot find the step that fetches the upstream tags"
	echo "$pass passed, $fail failed"; exit 1
fi
check "the step's run block has no expression in it" 0 "$(grep -c '\${{' "$S/run.sh")"

WS="$S/ws"; BIN="$S/bin"
mkdir -p "$WS/scripts/upstream" "$BIN"
# The fake verifier: logs "<repository directory> <tag>", refuses the tag named in
# $REFUSE, and otherwise prints the commit $ANSWER_<directory> or the clone's own.
cat > "$WS/scripts/upstream/verify-tag.sh" <<'SH'
#!/usr/bin/env bash
dir="${1##*/}"; echo "$dir $2" >> "$CALLS"
[ "$2" != "${REFUSE:-}" ] || { echo "$2 has no good signature from a key of upstream" >&2; exit 1; }
var="ANSWER_$dir"; echo "${!var:-commit-of-$dir}"
SH
# The fake git: `clone` makes the directory and logs it, `-C <dir> rev-parse HEAD`
# prints the commit of that clone.
cat > "$BIN/git" <<'GIT'
#!/usr/bin/env bash
if [ "$1" = clone ]; then
	dest="${*: -1}"; mkdir -p "$dest"; echo "clone ${dest##*/}" >> "$CALLS"; exit 0
fi
if [ "$1" = -C ] && [ "$3" = rev-parse ]; then echo "commit-of-${2##*/}"; exit 0; fi
exit 1
GIT
chmod +x "$BIN/git"

fetch() { # [VAR=value]...: run the step with the plan's commits unless overridden
	rm -rf "$S/rt"; mkdir -p "$S/rt"; : > "$S/calls"
	run_step "$S" "$WS" PATH="$BIN:$PATH" RUNNER_TEMP="$S/rt" CALLS="$S/calls" \
		PODMAN=v6.2.0 NETAVARK=v2.1.0 AARDVARK=v2.1.3 \
		PODMAN_SHA=commit-of-podman NETAVARK_SHA=commit-of-netavark AARDVARK_SHA=commit-of-aardvark "$@"
}
calls() { paste -sd'|' "$S/calls"; }

fetch
check "three signed tags the plan resolved: the step passes" 0 "$rc"
check "and each source is verified right after it is cloned, with its own tag" \
	"clone podman|podman v6.2.0|clone netavark|netavark v2.1.0|clone aardvark|aardvark v2.1.3" "$(calls)"
check "and each is reported as verified" 3 "$(says 'verified ')"

fetch REFUSE=v2.1.0
check "a tag the verifier refuses stops the step" 1 "$rc"
check "with the verifier's reason" 1 "$(says 'has no good signature from a key of upstream')"
check "and it is not reported as verified" 0 "$(says 'verified netavark')"
check "and nothing after it is fetched" "clone podman|podman v6.2.0|clone netavark|netavark v2.1.0" "$(calls)"

fetch REFUSE=v6.2.0
check "the first tag refused: nothing is reported as verified and nothing else is cloned" \
	"1 0 clone podman|podman v6.2.0" "$rc $(says 'verified ') $(calls)"

fetch ANSWER_netavark=another-commit NETAVARK_SHA=another-commit
check "a verified tag that is not the commit checked out stops the step" "1 0" "$rc $(says 'verified netavark')"

fetch NETAVARK_SHA=what-the-plan-saw
check "a verified tag that moved since the plan stops the step" 1 "$rc"
check "and it says which commit the plan saw" 1 "$(says 'netavark v2.1.0 is at commit-of-netavark, the plan saw what-the-plan-saw')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
