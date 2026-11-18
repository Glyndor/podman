#!/usr/bin/env bash
#
# Prove a release that cannot run the package refuses it. Run as root inside a
# clean container of that release (Ubuntu 22.04: glibc 2.35, older than the
# 2.39 netavark needs). Installing must fail, and fail because of libc6, not
# for an unrelated reason that would leave the real gap unnoticed.
#
# The package once declared libc6 without a version, apt installed it on Ubuntu
# 22.04 and every binary then failed with "GLIBC_2.39 not found".
#
# Usage: refuse-test.sh <deb>

set -euo pipefail

deb="${1:?deb}"
[ -f "$deb" ] || { echo "no such file: $deb" >&2; exit 2; }

# An end-of-life Ubuntu moves its archive to old-releases. The release this runs
# on exists to be old, so a 404 from the live archive is the expected day, not a
# reason to stop publishing: point apt at old-releases and try once more. amd64
# reads archive and security.ubuntu.com, arm64 reads ports.ubuntu.com.
if ! apt-get update -qq; then
	# shellcheck disable=SC2086 # the list of files is meant to be split and globbed
	sed -i -E 's#https?://([a-z]{2}\.)?(archive|security|ports)\.ubuntu\.com#http://old-releases.ubuntu.com#g' ${APT_SOURCES:-/etc/apt/sources.list /etc/apt/sources.list.d/*} 2>/dev/null || true
	apt-get update -qq
fi
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if apt-get install -y --no-install-recommends "$deb" > "$log" 2>&1; then
	echo "the package installed on a release whose glibc is too old for it" >&2
	exit 1
fi
grep -q 'libc6' "$log" || { echo "the install failed, but not because of libc6:" >&2; cat "$log" >&2; exit 1; }
echo "refused as expected: $(grep -m1 'libc6' "$log" | sed 's/^ *//')"
