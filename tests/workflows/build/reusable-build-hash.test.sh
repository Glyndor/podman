#!/usr/bin/env bash
#
# Tests for the step of reusable-build.yml that hashes the package before the artifact is made and before any job
# runs it: exactly one package, with the name the version and the architecture give, and its sha256 as the output
# the signer compares the downloaded file with. The step is read from the workflow and run under the shell the
# workflow gives it.
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
rc=0
if step reusable-build.yml build "name=Hash the package" "$S"; then
	hash_of() { # <file names in out/...>: runs the step with those files, sets $rc, $out and $S/out
		rm -rf "$S/rt"; mkdir -p "$S/rt/out"
		local f
		for f in "$@"; do printf '%s' "$f" > "$S/rt/out/$f"; done
		: > "$S/github-output"
		run_step "$S" "$WORK" RUNNER_TEMP="$S/rt" VERSION=6.2.0+r3 ARCH=amd64 GITHUB_OUTPUT="$S/github-output"
	}
	hash_of podman_6.2.0+r3_amd64.deb
	check "one package with the name of the version and the architecture: its sha256 is the output" "0 sha256=$(printf '%s' podman_6.2.0+r3_amd64.deb | sha256sum | cut -d' ' -f1)" "$rc $(cat "$S/github-output")"
	hash_of
	check "no package is refused" "1 1" "$rc $(says 'left 0 packages')"
	hash_of podman_6.2.0+r3_amd64.deb podman_6.2.0+r3_arm64.deb
	check "two packages are refused" "1 1" "$rc $(says 'left 2 packages')"
	hash_of podman_6.2.0+r3_arm64.deb
	check "a package of another architecture is refused, and named" "1 1" "$rc $(says 'is called podman_6.2.0+r3_arm64.deb, not podman_6.2.0+r3_amd64.deb')"
	check "and nothing is handed on" "" "$(cat "$S/github-output")"
else
	fail=$((fail + 1)); echo "FAIL  reusable-build.yml: cannot find the step that hashes the package"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
