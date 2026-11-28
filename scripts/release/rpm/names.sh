#!/usr/bin/env bash
#
# The exact names of the rpm packages a release is made of, derived from the version and from the
# tables of scripts/package, never from anything a build job left behind. Every job that stages,
# gathers, checks, signs or publishes asks this script, so "a package is missing" and "a package
# too many" are the same comparison everywhere.
#
#   legs                          one "<id> <arch>" per line, every distribution and architecture
#                                 of the rpm rows of distros.txt
#   leg <version> <id> <arch>     what the build of that distribution and architecture leaves: the
#                                 podman of the architecture, the two noarch packages, and the
#                                 dependencies the row takes beside podman
#   release <version>             what the release carries: every file of every leg once, with the
#                                 noarch packages taken from the x86_64 leg
#
# <version> is the release version, the tag without its leading v (X.Y.Z or X.Y.Z+rN). The names are
# those of the contract (docs/packages.md): <name>-<version>-<R>.glyndor.<id>.<arch>.rpm, where
# podman and its subpackages carry X.Y.Z+rR and a dependency carries its own version of extras.txt.
#
# GLYNDOR_DISTROS_FILE and GLYNDOR_EXTRAS_FILE name other tables, for tests.
#
# Usage: names.sh legs | leg <version> <id> <arch> | release <version>
# Exit 0 when the names are printed, 1 when a table or an argument cannot give them, 2 for a usage error.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
distros="$here/../../package/distros.sh"
extras="${GLYNDOR_EXTRAS_FILE:-$here/../../package/extras.txt}"
usage() { echo "usage: names.sh legs | leg <version> <id> <arch> | release <version>" >&2; exit 2; }
die() { echo "$*" >&2; exit 1; }

field() { bash "$distros" field "$1" "$2" || die "distros.txt does not say the $2 of $1"; }

rpm_ids() {
	local ids
	ids="$(bash "$distros" ids rpm)" || die "the rpm rows of distros.txt cannot be read"
	[ -n "$ids" ] || die "distros.txt has no rpm row"
	printf '%s\n' "$ids"
}

# version <release version>: VR, the version the packages carry, and R, their revision
version() {
	vr="$(bash "$here/../../package/package-version.sh" "$1")" || die "'$1' is not a release version"
	r="${vr##*+r}"
}

# extra_version <name>: the version extras.txt pins for a dependency, exactly one
extra_version() {
	local found
	[ -f "$extras" ] || die "$extras is missing"
	found="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$extras" | awk -F'|' -v n="$1" '$1 == n {print $2}')"
	[[ "$found" =~ ^[0-9][0-9A-Za-z.]*$ ]] || die "extras.txt pins no single version for $1 (found '$found')"
	printf '%s' "$found"
}

# arch_files <id> <arch>, noarch_files <id>: the files of one leg, after version
arch_files() {
	local wanted name v
	printf 'podman-%s-%s.glyndor.%s.%s.rpm\n' "$vr" "$r" "$1" "$2"
	wanted="$(field "$1" extras)"
	for name in ${wanted//,/ }; do
		v="$(extra_version "$name")" || exit 1
		printf '%s-%s-%s.glyndor.%s.%s.rpm\n' "$name" "$v" "$r" "$1" "$2"
	done
}
noarch_files() {
	local name
	for name in podman-docker podmansh; do
		printf '%s-%s-%s.glyndor.%s.noarch.rpm\n' "$name" "$vr" "$r" "$1"
	done
}

case "${1:-}" in
	legs)
		[ "$#" -eq 1 ] || usage
		ids="$(rpm_ids)"
		for id in $ids; do
			arches="$(field "$id" arches)"
			for arch in ${arches//,/ }; do printf '%s %s\n' "$id" "$arch"; done
		done ;;
	leg)
		[ "$#" -eq 4 ] || usage
		version "$2"
		[ "$(field "$3" format)" = rpm ] || die "$3 is not an rpm distribution"
		arches="$(field "$3" arches)"
		case ",$arches," in *",$4,"*) ;; *) die "$3 is not built for $4" ;; esac
		arch_files "$3" "$4"
		noarch_files "$3" ;;
	release)
		[ "$#" -eq 2 ] || usage
		version "$2"
		ids="$(rpm_ids)"
		for id in $ids; do
			arches="$(field "$id" arches)"
			case ",$arches," in *,x86_64,*) ;; *) die "$id is not built for x86_64, the leg the noarch packages come from" ;; esac
			for arch in ${arches//,/ }; do arch_files "$id" "$arch"; done
			noarch_files "$id"
		done ;;
	*) usage ;;
esac
