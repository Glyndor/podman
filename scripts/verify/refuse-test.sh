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

apt-get update -qq
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if apt-get install -y --no-install-recommends "$deb" > "$log" 2>&1; then
	echo "the package installed on a release whose glibc is too old for it" >&2
	exit 1
fi
grep -q 'libc6' "$log" || { echo "the install failed, but not because of libc6:" >&2; cat "$log" >&2; exit 1; }
echo "refused as expected: $(grep -m1 'libc6' "$log" | sed 's/^ *//')"
