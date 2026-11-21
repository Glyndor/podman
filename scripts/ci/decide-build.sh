#!/usr/bin/env bash
#
# Say whether a pull request has to build the package. It reads the paths the
# pull request changes, one per line, on stdin and prints "true" or "false".
#
# "true" when a path is something the package is built from or checked with:
# the build recipe, the verification scripts, the upstream scripts, the keys that
# verify upstream tags, the two workflows that run the build, the release
# workflow, and this script. Anything else (docs, tests, the other workflows)
# cannot change what the build produces.
#
# It fails open. An empty or unreadable list, or a path git printed quoted,
# prints "true": a wrong skip lets a change to the release path merge without
# the build having looked at it, and a wrong run costs about ten minutes.
#
# The workflow reads this file from the base commit, not from the pull request,
# so a pull request cannot rewrite it to skip its own build.
#
# Usage: git diff --name-only <base> <head> | decide-build.sh

set -u

list="$(cat 2>/dev/null)" || { echo true; exit 0; }

seen=0
while IFS= read -r path; do
	[ -n "$path" ] || continue
	seen=1
	path="${path#./}"
	case "$path" in
		scripts/build/* | scripts/verify/* | scripts/upstream/* | keyring/podman/* \
			| .github/workflows/reusable-build.yml \
			| .github/workflows/build-check.yml \
			| .github/workflows/release.yml \
			| scripts/ci/decide-build.sh)
			echo true; exit 0 ;;
		# git quotes a path with unusual characters; a quoted path cannot be
		# compared with the patterns above, so it counts as a hit.
		\"*) echo true; exit 0 ;;
	esac
done <<< "$list"

[ "$seen" -eq 1 ] || { echo true; exit 0; }
echo false
