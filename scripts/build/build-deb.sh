#!/usr/bin/env bash
#
# Build podman_<version>_<arch>.deb from three verified upstream source trees:
# Podman, netavark and aardvark-dns. Debian 13 carries netavark 1.14, which
# lacks the commands Podman 6 calls, so the matching network stack ships inside
# the package and replaces the distribution's copy. Runs on Debian 13 with the
# build dependencies installed; the workflow does the install in a job that
# holds no secrets, and nothing touches the .deb after this script writes it.
#
# Usage: build-deb.sh <podman-src> <netavark-src> <aardvark-dns-src> <version> <output-dir>
#   <version> is the release version without the v: 6.2.0 or 6.2.0+r2

set -euo pipefail

podman_src="$(cd "${1:?podman source dir}" && pwd)"
netavark_src="$(cd "${2:?netavark source dir}" && pwd)"
aardvark_src="$(cd "${3:?aardvark-dns source dir}" && pwd)"
version="${4:?version without the v}"
out="$(mkdir -p "${5:?output dir}" && cd "$5" && pwd)"
arch="$(dpkg --print-architecture)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || { echo "bad version: $version" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# GOTOOLCHAIN=auto lets the go in Debian 13 fetch the exact toolchain go.mod
# asks for; the module proxy checks it against the Go checksum database.
export GOTOOLCHAIN=auto
make -C "$podman_src" PREFIX=/usr >&2
make -C "$podman_src" install PREFIX=/usr DESTDIR="$stage" >&2

# The Rust components install into /usr/libexec/podman, a directory Podman
# searches for its helpers.
for src in "$netavark_src" "$aardvark_src"; do
	make -C "$src" >&2
	make -C "$src" install PREFIX=/usr DESTDIR="$stage" >&2
done

# Release artifacts ship stripped (releases standard): drop debug symbols from every ELF.
find "$stage" -type f -exec sh -c 'file -b "$1" | grep -q "^ELF" && strip --strip-unneeded "$1"' _ {} \; 2>/dev/null || true

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
Depends: conmon, crun | runc, golang-github-containers-common, init-system-helpers, nftables${libs:+, $libs}
Recommends: ca-certificates, catatonit | tini | dumb-init, passt, uidmap, dbus-user-session
Provides: netavark, aardvark-dns
Conflicts: netavark, aardvark-dns
Replaces: netavark, aardvark-dns
Description: Podman with its network stack, built from the upstream releases
 Daemonless container engine, packaged from the signed upstream tags of Podman,
 netavark and aardvark-dns. The two network components replace the older
 copies in Debian 13.
CONTROL

dpkg-deb --root-owner-group -Zxz --build "$stage" "$out/podman_${version}_${arch}.deb" >/dev/null
echo "$out/podman_${version}_${arch}.deb"
