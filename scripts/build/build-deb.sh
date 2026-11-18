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
# Podman's own Makefile picks the apparmor and btrfs tags when it finds their headers,
# and the build image has them, so Debian's AppArmor profile support and the btrfs
# storage driver are on as they are in Debian's package. Neither links a shared library.
#
# What Fedora's spec for this release does, and Debian's package does too: build with
# -trimpath (the Makefile sets it as a make variable, which go never sees), a position
# independent executable, control-flow protection and full RELRO. The commit date and
# an origin go into the binary so the same tag gives the same Podman.
export GOFLAGS="-trimpath -buildmode=pie"
# Control-flow protection is spelled differently per architecture: -fcf-protection is
# x86 only (gcc refuses it on arm64), whose counterpart is -mbranch-protection.
case "$arch" in
	amd64) flow_protection="-fcf-protection=full" ;;
	arm64) flow_protection="-mbranch-protection=standard" ;;
	*) flow_protection="" ;;
esac
export CGO_CFLAGS="-O2 -g $flow_protection -D_FORTIFY_SOURCE=2"
export CGO_LDFLAGS="-Wl,-z,relro -Wl,-z,now"
SOURCE_DATE_EPOCH="$(git -C "$podman_src" log -1 --format=%ct 2>/dev/null || date +%s)"
export SOURCE_DATE_EPOCH
make -C "$podman_src" PREFIX=/usr EXTRA_BUILDTAGS=containers_image_openpgp \
	BUILD_INFO="$SOURCE_DATE_EPOCH" BUILD_ORIGIN="Glyndor" >&2
# The binary has to carry what was asked for; a Makefile that stops passing a flag
# along would otherwise ship without it and nothing would say so.
if command -v go >/dev/null && [ -f "$podman_src/bin/podman" ]; then
	built="$(go version -m "$podman_src/bin/podman" 2>/dev/null || true)"
	for want in '-trimpath=true' '-buildmode=pie' 'apparmor' 'seccomp' 'systemd'; do
		printf '%s' "$built" | grep -q -- "$want" || { echo "the built podman lacks $want" >&2; exit 1; }
	done
fi
make -C "$podman_src" install PREFIX=/usr DESTDIR="$stage" >&2
# `install` does not put the shell completions in place; Debian's own package ships
# them, so a customer who moves to this one would otherwise lose tab completion.
# A shell tab completion is generated from the binary just built, so this runs after.
make -C "$podman_src" install.completions PREFIX=/usr DESTDIR="$stage" >&2

# The containers-common configuration of this release (0.70 for Podman 6.2.0), which
# upstream's spec requires at 0.68 or newer. Debian 13, Ubuntu 24.04 and 26.04 carry
# 0.62, 0.57 and 0.66: their seccomp profile, for one, lacks the futex_wait family and
# on 24.04 fchmodat2. The package provides it instead of depending on the distribution's.
common_version="$("$(dirname "$0")/install-common-config.sh" "$podman_src" "$stage" "${GLYNDOR_SHORTNAMES:-/usr/share/glyndor-build/shortnames.conf}")"

# The Rust components install into /usr/libexec/podman, a directory Podman
# searches for its helpers.
# --locked makes cargo build exactly the dependency versions in the Cargo.lock of the
# signed tag and fail if they would change. netavark's Makefile adds it only when
# CI is set, so without this a build could pick newer crates than upstream tested.
# Podman needs nothing: its Go modules come from the vendor tree of the tag.
for src in "$netavark_src" "$aardvark_src"; do
	[ -f "$src/Cargo.lock" ] || { echo "$src has no Cargo.lock to build against" >&2; exit 1; }
	make -C "$src" CARGO="cargo --locked" >&2
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
	*gpgme*|*assuan*|*subid*|*sqlite*|*apparmor*|*btrfs*)
		echo "build links a library that differs between releases: $libs" >&2
		exit 1 ;;
esac

# Debian's aardvark-dns asks for netavark (>> 1.14), and an unversioned Provides does
# not satisfy a versioned dependency, so the Provides carries the versions built here.
crate_version() { awk -F'"' '/^version *=/ {print $2; exit}' "$1/Cargo.toml"; }
netavark_version="$(crate_version "$netavark_src")"
aardvark_version="$(crate_version "$aardvark_src")"
[[ "$netavark_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$aardvark_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| { echo "cannot read the netavark or aardvark-dns version from Cargo.toml" >&2; exit 1; }

# A host that ran the distribution's Podman keeps the crun that came with it. Ubuntu 24.04
# ships 1.14, which cannot read the runtime spec Podman 6 writes ("unknown version
# specified"), and Podman prefers crun over runc, so the Depends alternative is not enough:
# the old crun has to go, and runc takes its place.
mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: podman
Version: $version
Architecture: $arch
Maintainer: Glyndor <noreply@glyndor.net>
Section: admin
Priority: optional
Homepage: https://podman.io
Depends: conmon (>= 2.1.7), crun (>= 1.21) | runc, catatonit, init-system-helpers, nftables${libs:+, $libs}
Recommends: ca-certificates, passt, uidmap, dbus-user-session, criu
Provides: netavark (= $netavark_version), aardvark-dns (= $aardvark_version), golang-github-containers-common (= $common_version), podman-remote
Conflicts: netavark, aardvark-dns, golang-github-containers-common, podman-remote
Breaks: crun (<< 1.21)
Replaces: netavark, aardvark-dns, golang-github-containers-common, podman-remote
Description: Podman with its network stack, built from the upstream releases
 Daemonless container engine, packaged from the signed upstream tags of Podman,
 netavark and aardvark-dns, with the containers-common configuration it asks for.
 The network components and that configuration replace the older copies the
 distributions ship.
CONTROL

dpkg-deb --root-owner-group -Zxz --build "$stage" "$out/podman_${version}_${arch}.deb" >/dev/null
echo "$out/podman_${version}_${arch}.deb"
