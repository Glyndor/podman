#!/usr/bin/env bash
#
# Clone Podman, netavark and aardvark-dns at the tags being tested and check each tag's
# signature with the same script and keys the release uses. Fails if a tag is not
# signed by a key the Podman maintainers authorise.
#
# Usage: fetch-sources.sh <directory> <podman tag> <netavark tag> <aardvark-dns tag>

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$(mkdir -p "${1:?directory}" && cd "$1" && pwd)"

fetch() { # <directory> <repository> <tag>
	git clone --quiet --branch "$3" "https://github.com/containers/$2.git" "$dest/$1"
	commit="$(bash "$here/../upstream/verify-tag.sh" "$dest/$1" "$3")"
	[ "$(git -C "$dest/$1" rev-parse HEAD)" = "$commit" ]
	echo "verified $2 $3 at $commit"
}
fetch podman podman "${2:?podman tag}"
fetch netavark netavark "${3:?netavark tag}"
fetch aardvark-dns aardvark-dns "${4:?aardvark-dns tag}"
