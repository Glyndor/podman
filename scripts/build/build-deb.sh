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
# containers_image_openpgp uses Go's own OpenPGP instead of gpgme, and the build
# image has no subid or sqlite headers, so Podman links only libseccomp. That is
# what lets one package install on Debian 13 and on Ubuntu 24.04 and 26.04,
# whose gpgme and subid libraries have different names.
make -C "$podman_src" PREFIX=/usr EXTRA_BUILDTAGS=containers_image_openpgp >&2
make -C "$podman_src" install PREFIX=/usr DESTDIR="$stage" >&2
# `install` does not put the shell completions in place; Debian's own package ships
# them, so a customer who moves to this one would otherwise lose tab completion.
# A shell tab completion is generated from the binary just built, so this runs after.
make -C "$podman_src" install.completions PREFIX=/usr DESTDIR="$stage" >&2

# The Rust components install into /usr/libexec/podman, a directory Podman
# searches for its helpers.
for src in "$netavark_src" "$aardvark_src"; do
	make -C "$src" >&2
	make -C "$src" install PREFIX=/usr DESTDIR="$stage" >&2
done

# Release artifacts ship stripped (releases standard): drop debug symbols from every ELF.
find "$stage" -type f -exec sh -c 'file -b "$1" | grep -q "^ELF" && strip --strip-unneeded "$1"' _ {} \; 2>/dev/null || true

# The newest glibc symbol any binary asks for. libc6 has to be declared with it:
# without a version apt installs the package on a release whose glibc is older
# and every binary then fails to start (measured on Ubuntu 22.04, where netavark
# needs 2.39 and the release has 2.35).
glibc_min="$(find "$stage" -type f -perm -u+x -print0 \
	| xargs -0 -r objdump -T 2>/dev/null \
	| grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -V | tail -n 1 || true)"

# Shared libraries the binaries really link against, as Debian package names.
libs="$(find "$stage" -type f -perm -u+x -print0 \
	| xargs -0 -r ldd 2>/dev/null \
	| awk '$3 ~ /^\// {print $3}' | sort -u \
	| xargs -r -n1 realpath | xargs -r dpkg -S 2>/dev/null \
	| sed 's/:[a-z0-9]*:.*//; s/: .*//' | sort -u \
	| sed "s/^libc6\$/libc6 (>= ${glibc_min:-2.0})/" | paste -sd, | sed 's/,/, /g')"

# These libraries are renamed between Debian and Ubuntu releases; a binary linked
# to one would not start elsewhere, so a build that picks one up is refused.
case ",$libs," in
	*gpgme*|*assuan*|*subid*|*sqlite*)
		echo "build links a library that differs between releases: $libs" >&2
		exit 1 ;;
esac

mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: podman
Version: $version
Architecture: $arch
Maintainer: Glyndor <noreply@glyndor.net>
Section: admin
Priority: optional
Homepage: https://podman.io
Depends: conmon, crun (>= 1.21) | runc, golang-github-containers-common, init-system-helpers, nftables${libs:+, $libs}
Recommends: ca-certificates, catatonit | tini | dumb-init, passt, uidmap, dbus-user-session, criu
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
