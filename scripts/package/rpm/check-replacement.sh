#!/usr/bin/env bash
#
# Fail when the distribution has a package that requires podman in a way this package cannot
# satisfy and does not replace. A host that has such a package installed would see its next
# update fail: `dnf upgrade` cannot install a podman that the package needs at another exact
# version, or at an epoch above the one this package carries.
#
# It lists everything in the repositories of the build image that requires podman and reads
# what it requires of it. Covered, and so not asked about: the packages of ours that require
# podman at the exact version they are built with (podman-docker, podmansh), and the ones
# this package obsoletes (podman-machine, podman-tests). Any other requirer is fine when it
# asks for a version at or below this package's, with an epoch that is not above it, and is a
# failure when it asks for an exact version or a higher epoch. Run in the build container of
# an rpm distribution that uses dnf (a query that fails, or that comes back empty where it cannot be, is a failure); openSUSE has no equivalent query and is covered by the
# package test, which installs the distribution's packages first.
#
# Usage: check-replacement.sh <id>

set -euo pipefail

id="${1:?distribution id}"
scripts="${GLYNDOR_SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
epoch="$(bash "$scripts/package/distros.sh" field "$id" epoch)"
covered=" podman-docker podmansh podman-machine podman-tests "

# Every query is an assignment of its own, so a dnf that fails (no network, a broken
# repository, a query it does not understand) stops the script instead of reading as an empty
# answer. An empty list is not an answer either where it is known not to be empty: a
# distribution that ships podman has podman-docker, which requires it.
requirers="$(dnf repoquery --whatrequires podman --qf '%{name}\n' | sort -u)" \
	|| { echo "cannot ask the repositories what requires podman" >&2; exit 1; }
case "$(bash "$scripts/package/distros.sh" field "$id" family)" in
	fedora | el)
		printf '%s\n' "$requirers" | grep -q -x podman-docker \
			|| { echo "the repositories do not list podman-docker among what requires podman, so the answer cannot be trusted" >&2; exit 1; } ;;
esac

bad=""
for pkg in $requirers; do
	case "$covered" in *" $pkg "*) continue ;; esac
	reqs="$(dnf repoquery --requires "$pkg")" || { echo "cannot ask the repositories what $pkg requires" >&2; exit 1; }
	# What the package says about podman: `podman`, `podman >= 2:4.8-1`, `podman = 5:6.2.0-1.fc45`.
	# grep answers 1 for no line, which is a package that asks nothing of podman here, and
	# anything above that is grep failing.
	rc=0
	wants="$(printf '%s\n' "$reqs" | grep -E '^podman( |$)')" || rc=$?
	[ "$rc" -le 1 ] || { echo "cannot read what $pkg requires" >&2; exit 1; }
	while IFS= read -r want; do
		[ -n "$want" ] || continue
		read -r _ op ver <<< "$want"
		if [ "${op:-}" = "=" ]; then
			bad="$bad$pkg requires podman exactly ($ver)\n"
		elif [[ "${ver:-}" =~ ^([0-9]+): ]] && [ "${BASH_REMATCH[1]}" -gt "$epoch" ]; then
			bad="$bad$pkg requires podman at epoch ${BASH_REMATCH[1]}, above the $epoch of this package\n"
		fi
	done <<< "$wants"
done
if [ -n "$bad" ]; then
	printf '%b' "$bad" >&2
	echo "the distribution has packages that this one neither satisfies nor replaces; cover them before building" >&2
	exit 1
fi
echo "every package of $id that requires podman is satisfied or replaced"
