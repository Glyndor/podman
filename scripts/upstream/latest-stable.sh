#!/usr/bin/env bash
#
# Print the highest stable upstream tag (vMAJOR.MINOR.PATCH) of Podman.
# Pre-releases (-rc1, -dev) and anything that is not plain SemVer are ignored.
#
# Usage: latest-stable.sh [repository-url]   (default: containers/podman)

set -euo pipefail

repo="${1:-https://github.com/containers/podman.git}"

tag="$(git ls-remote --tags --refs "$repo" \
	| sed 's#.*refs/tags/##' \
	| grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
	| sort -V | tail -n 1)"

[ -n "$tag" ] || { echo "no stable tag found in $repo" >&2; exit 1; }
echo "$tag"
