#!/usr/bin/env bash
#
# Step 4b: the run-time dependencies the distribution does not have, or has in a version
# that is too old, built from the upstream source so the start-up tests can still run and
# the result can say whether packaging them next to Podman works: passt, crun, conmon and
# catatonit. The first two are the ones the Debian package also has to replace.
#
# None of these sources is verified like the three tags are: passt and conmon publish no
# signature this probe checks, and neither do the tarball of crun and the tree of
# catatonit. This is a measurement of whether they build, not a recipe for a package.

# shellcheck disable=SC2317
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

status=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# latest_tag <repository url> <tag pattern>: the newest tag that matches.
latest_tag() {
	git ls-remote --tags --refs "$1" | sed 's|.*/||' | grep -E "$2" | sort -V | tail -n 1
}

# built <name> <tag> <command...>: run the build, log it and record how it ended.
built() {
	local name="$1" tag="$2" log="$PROBE_OUT/logs/build-$1.log"
	shift 2
	if [ -n "$tag" ] && "$@" > "$log" 2>&1; then
		fact "build.$name" "ok ($tag)"
	else
		tail -n 40 "$log" 2> /dev/null
		fact "build.$name" "fail (${tag:-no tag found})"
		fail "$name did not build"
		status=1
	fi
}

build_passt() {
	git clone --quiet --depth 1 --branch "$1" https://passt.top/passt "$work/passt" \
		&& make -C "$work/passt" prefix=/usr \
		&& make -C "$work/passt" install prefix=/usr
}

build_crun() {
	curl -fsSL --retry 3 -o "$work/crun.tar.gz" "https://github.com/containers/crun/releases/download/$1/crun-$1.tar.gz" \
		&& tar -C "$work" -xzf "$work/crun.tar.gz" \
		&& (cd "$work/crun-$1" && ./configure --prefix=/usr && make -j"$(nproc)" && make install)
}

build_conmon() {
	git clone --quiet --depth 1 --branch "$1" https://github.com/containers/conmon "$work/conmon" \
		&& make -C "$work/conmon" PREFIX=/usr \
		&& make -C "$work/conmon" install PREFIX=/usr
}

build_catatonit() {
	git clone --quiet --depth 1 --branch "$1" https://github.com/openSUSE/catatonit "$work/catatonit" \
		&& (cd "$work/catatonit" && ./autogen.sh && ./configure --prefix=/usr && make -j"$(nproc)" && make install)
}

if [ "$(dep_verdict passt)" != ok ]; then
	tag="$(latest_tag https://passt.top/passt '^20[0-9]{2}_')"
	built passt "$tag" build_passt "$tag"
fi
if [ "$(dep_verdict crun)" != ok ]; then
	pm_try libcap-devel libcap yajl-devel libyajl-devel json-c-devel libjson-c-devel json-c glibc-static glibc-devel-static autoconf automake libtool python3 > /dev/null
	tag="$(latest_tag https://github.com/containers/crun '^[0-9]+\.[0-9]+(\.[0-9]+)?$')"
	built crun "$tag" build_crun "$tag"
fi
if [ "$(dep_verdict conmon)" != ok ]; then
	pm_try glib2-devel glib2 > /dev/null
	tag="$(latest_tag https://github.com/containers/conmon '^v2\.[0-9]+\.[0-9]+$')"
	built conmon "$tag" build_conmon "$tag"
fi
if [ "$(dep_verdict catatonit)" != ok ]; then
	pm_try autoconf automake libtool glibc-static glibc-devel-static > /dev/null
	tag="$(latest_tag https://github.com/openSUSE/catatonit '^v[0-9]+\.[0-9]+\.[0-9]+$')"
	built catatonit "$tag" build_catatonit "$tag"
fi
exit "$status"
