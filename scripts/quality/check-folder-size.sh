#!/usr/bin/env bash
#
# Fail when a folder holds more than twenty tracked files directly. A folder past that
# is a drawer, not an index, and the split is by what each file is for: tests/workflows
# is the example of one that was divided into a folder per subject.
#
# Only the files directly inside a folder count, so a folder of folders is fine. Two
# places are left out: .github/workflows, which GitHub reads only when it is flat, and
# any folder under a testdata component, whose contents are fixtures and not code.
#
# The number is the one to stay under, not a target: ten is where to start looking for
# a split. The files counted are the ones git tracks, so a file that is not added yet is
# not in the count, and one that was removed from the index is not either.
#
# Usage: check-folder-size.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
limit=20

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Written to a file first: a git that fails inside a pipe would read as a tree with
# nothing in it, and an empty tree passes.
git -C "$root" ls-files -z > "$tmp" 2> /dev/null \
	|| { echo "$root is not a git working tree, so its files cannot be counted" >&2; exit 1; }

over="$(awk -v RS='\0' -v limit="$limit" '
	{
		dir = "."
		if (match($0, /\/[^\/]*$/)) dir = substr($0, 1, RSTART - 1)
		if (dir == ".github/workflows" || ("/" dir "/") ~ /\/testdata\//) next
		count[dir]++
	}
	END { for (dir in count) if (count[dir] > limit) printf "  %s holds %d files directly\n", dir, count[dir] }
' "$tmp" | LC_ALL=C sort)"

if [ -n "$over" ]; then
	echo "::error::a folder holds more than $limit files directly:" >&2
	printf '%s\n' "$over" >&2
	echo "Split it into subfolders by what each file is for." >&2
	exit 1
fi

echo "folder size: no folder holds more than $limit files directly."
