#!/usr/bin/env bash
#
# Package the payload of scripts/package/build-payload.sh as pacman packages: podman and the
# split podman-docker, in the version X.Y.Z+rR. Run as root in the build container of Arch Linux,
# where makepkg is; makepkg refuses to run as root, so the packaging runs as a user made for it.
#
# Usage: build-pacman.sh <payload-dir> <version X.Y.Z+rR> <out-dir>

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cd "${1:?payload dir}" && pwd)"
version="${2:?version X.Y.Z+rR}"
out="$(mkdir -p "${3:?output dir}" && cd "$3" && pwd)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+r[0-9]+$ ]] || { echo "bad version, expected X.Y.Z+rR: $version" >&2; exit 1; }
[ -f "$payload/facts.env" ] || { echo "no facts.env in $payload: the payload was not built" >&2; exit 1; }
# shellcheck disable=SC1091
. "$payload/facts.env"
for v in NETAVARK_VERSION AARDVARK_VERSION COMMON_VERSION; do
	[ -n "${!v:-}" ] || { echo "facts.env has no $v" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
id -u packager > /dev/null 2>&1 || useradd -m packager
mkdir -p "$work/build" "$work/pkgdest"
chown packager "$work/build" "$work/pkgdest"
cp "$here/PKGBUILD" "$work/build/PKGBUILD"
chown packager "$work/build/PKGBUILD"
# The payload is read by the packager, so it has to be readable and its directories searchable;
# every path the user reads is under the work directory or the payload, both world readable.
chmod -R a+rX "$payload"
chmod a+rx "$work"
su packager -s /bin/bash -c "cd '$work/build' && \
	GL_VERSION='$version' GL_PAYLOAD='$payload' GL_NETAVARK='$NETAVARK_VERSION' GL_AARDVARK='$AARDVARK_VERSION' GL_COMMON='$COMMON_VERSION' \
	PKGDEST='$work/pkgdest' PACKAGER='Glyndor <noreply@glyndor.net>' makepkg --nodeps --force --noconfirm --skipinteg" >&2
cp "$work"/pkgdest/*.pkg.tar.zst "$out/"
ls "$out"/*.pkg.tar.zst
