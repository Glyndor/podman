#!/usr/bin/env bash
#
# Build podman_<version>_<arch>.deb from a verified upstream source tree.
# Runs on Debian 13 with the build dependencies installed; the workflow does the
# install in a job that holds no secrets. No third-party step touches the .deb
# after this script writes it.
#
# Usage: build-deb.sh <source-dir> <version> <output-dir>

set -euo pipefail

src="$(cd "${1:?source dir}" && pwd)"
version="${2:?version without the v}"
out="$(mkdir -p "${3:?output dir}" && cd "$3" && pwd)"
arch="$(dpkg --print-architecture)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $version" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# GOTOOLCHAIN=auto lets the go in Debian 13 fetch the exact toolchain go.mod
# asks for; the module proxy checks it against the Go checksum database.
export GOTOOLCHAIN=auto
make -C "$src" PREFIX=/usr >&2
make -C "$src" install PREFIX=/usr DESTDIR="$stage" >&2

# Shared libraries the binaries really link against, as Debian package names.
libs="$(find "$stage" -type f -perm -u+x -print0 \
	| xargs -0 -r ldd 2>/dev/null \
	| awk '$3 ~ /^\// {print $3}' | sort -u \
	| xargs -r -n1 realpath | xargs -r dpkg -S 2>/dev/null \
	| sed 's/:[a-z0-9]*:.*//; s/: .*//' | sort -u | paste -sd, | sed 's/,/, /g')"

mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: podman
Version: $version
Architecture: $arch
Maintainer: Glyndor <noreply@glyndor.net>
Section: admin
Priority: optional
Homepage: https://podman.io
Depends: conmon, crun | runc, golang-github-containers-common, netavark, init-system-helpers${libs:+, $libs}
Recommends: aardvark-dns, ca-certificates, catatonit | tini | dumb-init, passt, uidmap, dbus-user-session
Description: Podman, built from the upstream release
 Daemonless container engine, packaged from the signed upstream tag v$version.
CONTROL

dpkg-deb --root-owner-group -Zxz --build "$stage" "$out/podman_${version}_${arch}.deb" >/dev/null
echo "$out/podman_${version}_${arch}.deb"
