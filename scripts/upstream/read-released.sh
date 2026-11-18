#!/usr/bin/env bash
#
# Write the components.txt of the newest published release to <out>. The plan
# compares it with what upstream has now, and a difference means "build".
#
# An empty file means this repository has no release yet. A release that exists
# but whose components cannot be read is an error, never an empty file: read as
# "nothing released" it makes every scheduled run build and publish another +rN,
# with nobody asking. That is what happened once: the file was created empty
# first and `gh release download` refuses to overwrite it, and the failure was
# swallowed.
#
# Needs gh and, as for gh itself, GH_TOKEN and GH_REPO (or a repository checkout).
#
# Usage: read-released.sh <out>

set -euo pipefail

out="${1:?out file}"

latest="$(gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName // empty')"
rm -f "$out"
if [ -z "$latest" ]; then
	: > "$out"
	exit 0
fi

gh release download "$latest" --pattern components.txt --output "$out" --clobber \
	|| { echo "release $latest has no readable components.txt" >&2; exit 1; }
grep -q '^podman ' "$out" \
	|| { echo "components.txt of $latest names no podman version" >&2; exit 1; }
