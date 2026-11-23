#!/usr/bin/env bash
#
# The whole build of the pacman packages, inside the Arch Linux build container, as root: the
# build dependencies, the payload from the three verified source trees, and the packages. The
# workflow starts it and does nothing else in the container.
#
# The short-name list the package ships is the one in Arch's own containers-common, which pacman
# checked against the Arch keyring: upstream's spec fetches the head of a branch that carries no
# signature. Layout it expects: the sources at /src/{podman,netavark,aardvark}, this repository's
# scripts/ at /scripts (read only), and /out for the packages. GLYNDOR_SRC and GLYNDOR_SCRIPTS
# move them, for tests.
#
# Usage: run-build.sh <version X.Y.Z+rR> <out-dir>

set -euo pipefail

version="${1:?version X.Y.Z+rR}"
out="${2:?output dir}"
src="${GLYNDOR_SRC:-/src}"
scripts="${GLYNDOR_SCRIPTS:-/scripts}"

pacman -Syu --noconfirm --needed base-devel git go rust protobuf libseccomp systemd gettext binutils file python containers-common \
	|| { echo "the repositories of Arch lack a package the build requires" >&2; exit 1; }
# btrfs headers are optional: the build takes the btrfs tag only when they are there.
pacman -S --noconfirm --needed btrfs-progs || echo "no btrfs-progs here: the build goes without btrfs" >&2
# What the build runs has to be there now, not found in the middle of make.
bash "$scripts/package/require-tools.sh" pacman
bash "$scripts/package/pacman/check-replacement.sh"

shortnames="$(pacman -Ql containers-common | awk '{print $2}' | grep -m1 'shortnames\.conf$' || true)"
[ -s "$shortnames" ] || { echo "the distribution's containers-common ships no shortnames.conf" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git config --global --add safe.directory '*'
bash "$scripts/package/build-payload.sh" "$src/podman" "$src/netavark" "$src/aardvark" "$work/payload" arch "$shortnames" >&2
bash "$scripts/package/pacman/build-pacman.sh" "$work/payload" "$version" "$out"
