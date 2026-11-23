#!/usr/bin/env bash
#
# The version the rpm and pacman packages carry for a release: X.Y.Z+rR, with the revision
# always written. The .deb carries the tag without its v (6.2.0 for the first build of a Podman
# version, 6.2.0+r12 for the twelfth); a native package writes the revision of the first one
# too (6.2.0+r1), so that it is newer than any build of that Podman version a distribution
# makes whatever release counter that one has, and older than the next Podman.
#
# Usage: package-version.sh <release version without the v>
#   6.2.0 -> 6.2.0+r1      6.2.0+r12 -> 6.2.0+r12

set -euo pipefail

version="${1:?release version without the v}"
[[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(\+r([0-9]+))?$ ]] || { echo "not a release version: $version" >&2; exit 1; }
upstream="${BASH_REMATCH[1]}"
revision="${BASH_REMATCH[3]:-1}"
[ "$revision" -ge 1 ] || { echo "a revision starts at 1: $version" >&2; exit 1; }
printf '%s+r%s\n' "$upstream" "$revision"
