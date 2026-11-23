#!/usr/bin/env bash
#
# Build what a native package (rpm, pacman) of this repository carries, from three verified
# upstream source trees, with the toolchain of the distribution it runs on: Podman, netavark
# and aardvark-dns, the containers-common configuration of the release, the completions and
# the man pages. It is the compile half of what scripts/build/build-deb.sh does for the .deb,
# written once for every distribution that is not Debian, and it leaves the packaging itself
# (rpmbuild, makepkg) to the script of each format.
#
# The tree it writes is split the way the distributions split their own Podman:
#   <payload>/main    podman, podman-remote, quadlet, netavark, aardvark-dns, the configuration
#   <payload>/docker  the docker shim and its man pages (package podman-docker)
#   <payload>/sh      podmansh, a link to podman, and its man page (package podmansh)
#   <payload>/facts.env  versions the packaging has to say: NETAVARK_VERSION, AARDVARK_VERSION,
#                        COMMON_VERSION
#
# The build asks for what upstream and the distributions ask for (position independent
# executable, -trimpath, full RELRO, BIND_NOW, control-flow protection, _FORTIFY_SOURCE=2) and
# checks that the binary carries it. It uses Go's own OpenPGP and links no gpgme, subid or
# sqlite, like the .deb, so the three packages are the same program. Run as root in the build
# container of a distribution, with the build dependencies installed; Go does not download a
# toolchain here, because the packages of the distribution must be enough.
#
# Usage: build-payload.sh <podman-src> <netavark-src> <aardvark-dns-src> <payload-dir> <family> <shortnames.conf>
#   <family> is fedora, el, amzn, suse or arch; the first four are built with SELinux support.
#   <shortnames.conf> is the short-name list of the distribution, taken from its signed package.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
podman_src="$(cd "${1:?podman source dir}" && pwd)"
netavark_src="$(cd "${2:?netavark source dir}" && pwd)"
aardvark_src="$(cd "${3:?aardvark-dns source dir}" && pwd)"
payload="$(mkdir -p "${4:?payload dir}" && cd "$4" && pwd)"
family="${5:?family}"
shortnames="${6:?shortnames.conf}"

case "$family" in
	fedora | el | amzn | suse) selinux=1 ;;
	arch) selinux=0 ;;
	*) echo "unknown family: $family" >&2; exit 2 ;;
esac
machine="$(uname -m)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$payload/main"
rm -rf "$payload/main" "$payload/docker" "$payload/sh"
mkdir -p "$stage" "$payload/docker" "$payload/sh"

# The distribution's own Go has to be new enough: a toolchain that Go downloads is code
# nobody reviewed, and the tabla of the distributions measured that none needs it.
export GOTOOLCHAIN=local
export GOFLAGS="-trimpath -buildmode=pie"
# Control-flow protection is spelled differently per architecture: -fcf-protection is x86
# only (gcc refuses it on aarch64), whose counterpart is -mbranch-protection.
case "$machine" in
	x86_64) flow_protection="-fcf-protection=full" ;;
	aarch64) flow_protection="-mbranch-protection=standard" ;;
	*) flow_protection="" ;;
esac
export CGO_CFLAGS="-O2 -g $flow_protection -D_FORTIFY_SOURCE=2"
export CGO_LDFLAGS="-Wl,-z,relro -Wl,-z,now"
SOURCE_DATE_EPOCH="$(git -C "$podman_src" log -1 --format=%ct 2>/dev/null || date +%s)"
export SOURCE_DATE_EPOCH
make -C "$podman_src" PREFIX=/usr EXTRA_BUILDTAGS=containers_image_openpgp \
	BUILD_INFO="$SOURCE_DATE_EPOCH" BUILD_ORIGIN="Glyndor" >&2

# The binary has to carry what was asked for: a Makefile that stops passing a flag along would
# otherwise ship without it and nothing would say so. A build that cannot read the build info
# is refused too, because skipping the check would ship exactly the package it exists to stop.
command -v go >/dev/null || { echo "no go to read the build info of the built podman" >&2; exit 1; }
[ -f "$podman_src/bin/podman" ] || { echo "make left no bin/podman to check" >&2; exit 1; }
built="$(go version -m "$podman_src/bin/podman")" \
	|| { echo "cannot read the build info of bin/podman" >&2; exit 1; }
wanted=('-trimpath=true' '-buildmode=pie' 'seccomp' 'systemd')
[ "$selinux" -eq 0 ] || wanted+=('selinux')
for want in "${wanted[@]}"; do
	printf '%s' "$built" | grep -q -- "$want" || { echo "the built podman lacks $want" >&2; exit 1; }
done
make -C "$podman_src" install PREFIX=/usr DESTDIR="$stage" >&2
make -C "$podman_src" install.completions PREFIX=/usr DESTDIR="$stage" >&2

# The docker shim and the podmansh link are separate packages in every distribution, because
# the first conflicts with Docker. They are taken out of the main tree, so each file has one
# owner. install.docker needs envsubst, from gettext.
make -C "$podman_src" install.docker install.docker-docs PREFIX=/usr ETCDIR=/etc DESTDIR="$payload/docker" >&2
[ -L "$stage/usr/bin/podmansh" ] || { echo "make install left no podmansh link" >&2; exit 1; }
install -d "$payload/sh/usr/bin" "$payload/sh/usr/share/man/man1"
mv "$stage/usr/bin/podmansh" "$payload/sh/usr/bin/podmansh"
if [ -e "$stage/usr/share/man/man1/podmansh.1" ]; then
	mv "$stage/usr/share/man/man1/podmansh.1" "$payload/sh/usr/share/man/man1/podmansh.1"
fi

# The containers-common configuration of this release, which upstream's spec asks for at
# 0.68 or newer: the distribution's package is replaced, whatever it holds.
common_version="$(bash "$here/../build/install-common-config.sh" "$podman_src" "$stage" "$shortnames")"

# --locked makes cargo build exactly the dependency versions in the Cargo.lock of the signed
# tag and fail if they would change. netavark's Makefile adds it only when CI is set.
for src in "$netavark_src" "$aardvark_src"; do
	[ -f "$src/Cargo.lock" ] || { echo "$src has no Cargo.lock to build against" >&2; exit 1; }
	make -C "$src" CARGO="cargo --locked" >&2
	make -C "$src" install PREFIX=/usr DESTDIR="$stage" >&2
done

# Every ELF of the three trees, listed once: an executable bit does not make a file a binary.
: > "$work/elf"; : > "$work/dynamic"
while IFS= read -r -d '' f; do
	if file -b "$f" | grep -q '^ELF'; then
		printf '%s\0' "$f" >> "$work/elf"
		if readelf -d "$f" 2>/dev/null | grep -q '(NEEDED)'; then printf '%s\0' "$f" >> "$work/dynamic"; fi
	fi
done < <(find "$stage" "$payload/docker" "$payload/sh" -type f -print0)

# Release artifacts ship stripped: drop debug symbols from every ELF, and refuse a binary that
# still has them, which means strip did not run.
xargs -0 -r strip --strip-unneeded < "$work/elf"
while IFS= read -r -d '' f; do
	! readelf -S "$f" 2>/dev/null | grep -q '\.debug_' || { echo "$f still has debug sections" >&2; exit 1; }
done < "$work/elf"

# These libraries are renamed between releases of a distribution and are not wanted: the build
# asked for Go's OpenPGP and for no subid or sqlite. A binary that picked one up carries a
# dependency the .deb does not have.
libs="$(xargs -0 -r ldd < "$work/dynamic" | awk '$3 ~ /^\// {print $3}' | sort -u)" \
	|| { echo "could not read the libraries the binaries link against" >&2; exit 1; }
case "$libs" in
	*gpgme* | *assuan* | *subid* | *sqlite*)
		echo "build links a library the package is not meant to depend on: $libs" >&2
		exit 1 ;;
esac

crate_version() { awk -F'"' '/^version *=/ {print $2; exit}' "$1/Cargo.toml"; }
netavark_version="$(crate_version "$netavark_src")"
aardvark_version="$(crate_version "$aardvark_src")"
for v in "$netavark_version" "$aardvark_version"; do
	[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cannot read the netavark or aardvark-dns version from Cargo.toml" >&2; exit 1; }
done

cat > "$payload/facts.env" <<FACTS
NETAVARK_VERSION=$netavark_version
AARDVARK_VERSION=$aardvark_version
COMMON_VERSION=$common_version
FACTS
echo "$payload"
