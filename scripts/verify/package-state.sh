#!/usr/bin/env bash
#
# The checks of smoke-test.sh that ask what the installed package left on the system
# rather than what it does, kept in a script of their own so a test can run them
# against a system it controls. smoke-test.sh needs root, apt and a clean container,
# and a check that cannot run anywhere else is a check nobody has seen fail.
#
# Usage: package-state.sh <check> [package...]
#   seccomp         /usr/share/containers/seccomp.json is the profile of this release,
#                   the one that lists futex_waitv, and not the older one of a distribution
#                   (GLYNDOR_SECCOMP_PROFILE names another file, for tests)
#   replaced <pkg>  the distribution's <pkg> is not installed next to this package
#   kept <pkg>...   every <pkg> is still installed, as buildah and skopeo must be after
#                   the upgrade from the distribution's Podman
#
# Exit 0 when the check holds, 1 when it does not, 2 for a usage error.

set -euo pipefail

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }

check="${1:-}"
[ "$#" -eq 0 ] || shift
case "$check" in
	seccomp)
		[ "$#" -eq 0 ] || { echo "seccomp takes no package" >&2; exit 2; }
		grep -q '"futex_waitv"' "${GLYNDOR_SECCOMP_PROFILE:-/usr/share/containers/seccomp.json}" \
			|| { echo "the seccomp profile is not this release's" >&2; exit 1; } ;;
	replaced)
		[ "$#" -eq 1 ] || { echo "replaced takes one package" >&2; exit 2; }
		! installed "$1" || { echo "the distribution's $1 is installed next to this package" >&2; exit 1; } ;;
	kept)
		[ "$#" -ge 1 ] || { echo "kept takes at least one package" >&2; exit 2; }
		for pkg in "$@"; do
			installed "$pkg" || { echo "$pkg was removed by the upgrade" >&2; exit 1; }
		done ;;
	*)
		echo "usage: package-state.sh seccomp | replaced <package> | kept <package>..." >&2
		exit 2 ;;
esac
