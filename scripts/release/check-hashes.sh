#!/usr/bin/env bash
#
# In the job that signs, after the download and before anything else reads it: require that each .deb is
# the file its build job hashed before any test ran it, and that the rpm packages are the set the
# packaging gathered. A hash that was not reported, a file that is not a regular one or a hash that
# differs stops the run before a key is read.
#
# Usage: check-hashes.sh <tag> <built-dir> <amd64-sha256> <arm64-sha256> <rpm-manifest>
#   <built-dir> holds deb-amd64/, deb-arm64/ and rpm/, as downloaded.
#   <rpm-manifest> is what scripts/release/rpm/collect.sh digest printed for the set that was gathered.
# Exit 0 when every file is the one hashed, 1 when one is not, 2 for a usage error.

set -euo pipefail

[ "$#" -eq 5 ] || { echo "usage: check-hashes.sh <tag> <built-dir> <amd64-sha256> <arm64-sha256> <rpm-manifest>" >&2; exit 2; }
tag="$1" built="$2" manifest="$5"
declare -A want=([amd64]="$3" [arm64]="$4")
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "::error::$*; refusing to sign." >&2; exit 1; }

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || die "the tag '$tag' is not a version"
version="${tag#v}"
for arch in amd64 arm64; do
	[[ "${want[$arch]}" =~ ^[0-9a-f]{64}$ ]] || die "the build of $arch reported the sha256 '${want[$arch]}', not a sha256"
	file="$built/deb-$arch/podman_${version}_${arch}.deb"
	[ "$(stat -c %F "$file" 2> /dev/null)" = "regular file" ] || die "$file is not a regular file"
	sum="$(sha256sum "$file")"
	[ "${sum%% *}" = "${want[$arch]}" ] || die "podman_${version}_${arch}.deb is ${sum%% *}, and the build hashed ${want[$arch]} before it ran"
done
[[ "$manifest" =~ ^[0-9a-f]{64}$ ]] || die "the packaging reported the hash '$manifest' of the rpm packages, not a sha256"
got="$(bash "$here/rpm/collect.sh" digest "$version" "$built/rpm")" || die "the rpm packages cannot be hashed"
[ "$got" = "$manifest" ] || die "the rpm packages hash to $got, and the packaging gathered $manifest"
echo "the .deb and the rpm packages of $tag are the files that were hashed where they were made"
