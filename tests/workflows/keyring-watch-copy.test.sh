#!/usr/bin/env bash
#
# Tests for the step of .github/workflows/keyring-watch.yml that copies upstream's
# keys into a branch: it copies a link as a link and never the file it points to, so
# a link in the clone of containers/release-keys cannot carry a file of this runner,
# such as one that holds a credential, into a branch of a public repository. The step
# before it refuses links (workflows-contract.test.sh); this is the second layer, and
# it is run here on its own, in a throwaway repository, with a link that step would
# have refused. It also replaces the whole set, so a key upstream dropped is dropped.
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

C="$WORK/copy"
if step keyring-watch.yml compare "name=Commit the update to a branch" "$C"; then
	check "the copy step's run block has no expression in it" 0 "$(grep -c '\${{' "$C/run.sh")"
	# The repository as checked out: two keys. Upstream: one of them, a new one, and a
	# link to a file of the runner.
	R="$C/repo"; UP="$C/rt/release-keys/podman"
	g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$R" "$@"; }
	mkdir -p "$R/keyring/podman" "$UP"
	echo kept > "$R/keyring/podman/kept.asc"; echo dropped > "$R/keyring/podman/dropped.asc"
	g init -q; g add -A; g -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false commit -q -m base
	echo kept > "$UP/kept.asc"; echo new > "$UP/new.asc"
	echo "a credential of the runner" > "$C/rt/token"
	ln -s "$C/rt/token" "$UP/link.asc"
	printf 'added new.asc\nremoved dropped.asc\n' > "$C/rt/diff.txt"
	: > "$C/out"
	run_step "$C" "$R" RUNNER_TEMP="$C/rt" GITHUB_OUTPUT="$C/out" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
	check "the update is committed to a branch, and the branch is handed on" "0 1" \
		"$rc $(grep -c '^branch=keyring/update-[0-9]\{8\}-[0-9]\{4\}$' "$C/out")"
	check "the link is committed as a link, the keys as files, and the key upstream dropped is gone" \
		"kept.asc:100644 link.asc:120000 new.asc:100644" \
		"$(g ls-tree -r HEAD keyring/podman | awk '{sub("keyring/podman/", "", $4); print $4 ":" $1}' | paste -sd' ')"
	check "and nothing the link points to is in the commit" 0 "$(g grep -c 'a credential' HEAD -- keyring | wc -l)"
	check "the commit is signed off" 1 "$(g log -1 --format=%B | grep -c '^Signed-off-by: github-actions\[bot\] ')"
else
	fail=$((fail + 1)); echo "FAIL  keyring-watch.yml: cannot find the copy step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
