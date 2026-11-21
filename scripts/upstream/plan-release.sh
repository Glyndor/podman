#!/usr/bin/env bash
#
# Decide whether a new release is needed and what to call it.
#
# Inputs (files, one "<component> <tag>" per line):
#   fresh     the newest stable tag upstream publishes for each component
#   released  the components of the newest release of this repository (may be empty);
#             lines for anything that is not a component in <fresh> are ignored
#   tags      release tags this repository already has, one per line (may be empty)
#
# Prints "build=false", or "build=true" and "tag=<tag>". The tag is v<podman
# version> the first time a Podman version is packaged, and v<version>+r<N> when
# a component changes under a Podman version that already has a release. The
# "+" keeps it part of the upstream version for the apt binding, and dpkg sorts
# 6.2.0+r2 after 6.2.0 and before 6.2.1.
#
# Usage: plan-release.sh <fresh> <released> <tags>

set -euo pipefail

fresh="${1:?fresh}"; released="${2:?released}"; tags="${3:?tags}"

# Tags with nothing released means the components of the newest release could
# not be read, not that nothing was ever released. Building on that guess is what
# publishes a new revision on every run.
if [ ! -s "$released" ] && [ -s "$tags" ]; then
	echo "this repository has release tags but no released components to compare with" >&2
	exit 1
fi

# Only the components the plan asked about are compared. components.txt is also a
# record of its release: a line in it that is not one of the components in <fresh> (the
# signature scheme, a date) is not something upstream or the recipe can change, and
# compared whole it would differ on every run, so every scheduled run would publish
# another +rN, forever. A component of <fresh> that the release does not list still
# differs, so a missing line is never read as a present one.
known() { awk 'NR == FNR {want[$1] = 1; next} $1 in want' "$fresh" "$1"; }
sort "$fresh" | cmp -s - <(known "$released" | sort) && { echo "build=false"; exit 0; }

podman="$(awk '$1 == "podman" {print $2}' "$fresh")"
[[ "$podman" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "no podman tag in $fresh" >&2; exit 1; }

# The next revision is one past the highest the repository already has for this
# Podman version, not a count of its tags: a count lands on a name that exists as
# soon as one revision is missing, and then every later run picks it again.
max=0
re="^$(printf '%s' "$podman" | sed 's/\./\\./g')(\\+r([0-9]+))?$"
while IFS= read -r t; do
	[[ "$t" =~ $re ]] || continue
	k="${BASH_REMATCH[2]:-1}"
	[ "$k" -le "$max" ] || max="$k"
done < "$tags"
if [ "$max" -eq 0 ]; then tag="$podman"; else tag="$podman+r$((max + 1))"; fi
echo "build=true"
echo "tag=$tag"
