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
# It prints the tag of that release, or nothing when there is none, so the second
# form can ask about the same release without looking it up again.
#
# The second form writes the names of the assets of release <tag> to <assets>, one per
# line, so the release can tell whether the newest one carries a second signature. It
# is asked only when a run is going to build, and the tag is the one the first form
# printed, so neither the release list nor components.txt is fetched twice. An empty
# <tag> is no release yet, and an empty file. A listing that cannot be read, or that
# does not even name components.txt, is an error: read as "no assets" it would say the
# newest release carried no second signature, which is the answer that lets the next
# one leave without it.
#
# Needs gh and, as for gh itself, GH_TOKEN and GH_REPO (or a repository checkout).
#
# Usage: read-released.sh <out>
#        read-released.sh --assets <tag> <assets>

set -euo pipefail

if [ "${1:-}" = --assets ]; then
	[ "$#" -eq 3 ] || { echo "usage: read-released.sh --assets <tag> <assets>" >&2; exit 2; }
	tag="$2"
	assets="$3"
	rm -f "$assets"
	if [ -z "$tag" ]; then
		: > "$assets"
		exit 0
	fi
	gh release view "$tag" --json assets --jq '.assets[].name' > "$assets" \
		|| { echo "cannot list the assets of release $tag" >&2; exit 1; }
	grep -qx 'components.txt' "$assets" \
		|| { echo "the asset list of release $tag does not name components.txt" >&2; exit 1; }
	exit 0
fi

out="${1:?out file}"
[ "$#" -eq 1 ] || { echo "usage: read-released.sh <out>" >&2; exit 2; }

latest="$(gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName // empty')"
rm -f "$out"
if [ -z "$latest" ]; then
	: > "$out"
	exit 0
fi

# Whatever gh prints goes to stderr: stdout carries the tag and nothing else.
gh release download "$latest" --pattern components.txt --output "$out" --clobber >&2 \
	|| { echo "release $latest has no readable components.txt" >&2; exit 1; }
grep -q '^podman ' "$out" \
	|| { echo "components.txt of $latest names no podman version" >&2; exit 1; }
printf '%s\n' "$latest"
