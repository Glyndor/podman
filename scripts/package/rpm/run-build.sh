#!/usr/bin/env bash
#
# The whole build of the rpm of one distribution, inside its build container, as root: its
# build dependencies, the payload from the three verified source trees, and the packages.
# The workflow starts it and does nothing else in the container, so what a build is lives
# here and can be read and tested without a runner.
#
# The short-name list the package ships is the one in the distribution's own containers-common
# (or its equivalent), which the package manager checked against the distribution's key:
# upstream's spec fetches the head of a branch that carries no signature.
#
# Layout it expects: the sources at /src/{podman,netavark,aardvark,extras}, this repository's
# scripts/ at /scripts (read only), and /out for the packages. GLYNDOR_SRC and GLYNDOR_SCRIPTS
# move them, for tests.
#
# Usage: run-build.sh <id> <version> <out-dir>

set -euo pipefail

id="${1:?distribution id}"
version="${2:?version X.Y.Z+rR}"
out="${3:?output dir}"
src="${GLYNDOR_SRC:-/src}"
scripts="${GLYNDOR_SCRIPTS:-/scripts}"

# distros.sh reads the table with awk, which the minimal image of openSUSE does not have.
command -v awk > /dev/null || { zypper --non-interactive install gawk || dnf install -y gawk; } > /dev/null 2>&1 || true
family="$(bash "$scripts/package/distros.sh" field "$id" family)"
extras="$(bash "$scripts/package/distros.sh" field "$id" extras)"
bash "$scripts/package/rpm/install-build-deps.sh" "$family" ${extras:+"$extras"}
# What the distribution has that requires podman has to be satisfied or replaced by this package.
bash "$scripts/package/rpm/check-replacement.sh" "$id"

case "$family" in
	suse) common_package=libcontainers-common; install=(zypper --non-interactive install --no-recommends) ;;
	*) common_package=containers-common; install=(dnf install -y --setopt=install_weak_deps=False) ;;
esac
"${install[@]}" "$common_package" \
	|| { echo "cannot install $common_package, the signed source of the short-name list" >&2; exit 1; }
shortnames="$(rpm -qa --qf '%{NAME}\n' | xargs rpm -ql 2>/dev/null | grep -m1 '/000-shortnames\.conf$' || true)"
[ -s "$shortnames" ] || { echo "the distribution's $common_package ships no 000-shortnames.conf" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# git refuses a tree owned by another user, and the sources are mounted from the runner.
git config --global --add safe.directory '*'
bash "$scripts/package/build-payload.sh" "$src/podman" "$src/netavark" "$src/aardvark" "$work/payload" "$family" "$shortnames" >&2
bash "$scripts/package/rpm/build-rpm.sh" "$work/payload" "$id" "$version" "$out"
# The dependencies this distribution takes beside podman, from the sources the runner verified.
bash "$scripts/package/rpm/build-extras.sh" "$id" "${version##*+r}" "$src/extras" "$out" >&2
