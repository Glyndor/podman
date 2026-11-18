#!/usr/bin/env bash
#
# Print a short id of how the package is built: the content of every file under
# scripts/build (the build image, the packaging script, this one).
#
# The release workflow records it next to the upstream tags. Upstream tags alone
# cannot see a packaging change, so a fix to the dependencies, or a new base
# image, would never produce a release and the published package would stay as
# it was. With the id, any change to how the package is built makes the next
# scheduled run publish a +rN release, with nobody having to remember to ask.
#
# Usage: recipe-id.sh [directory]    (default: scripts/build)

set -euo pipefail

dir="${1:-scripts/build}"
[ -d "$dir" ] || { echo "no such directory: $dir" >&2; exit 2; }

(cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-12
