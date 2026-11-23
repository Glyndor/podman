#!/usr/bin/env bash
#
# Package the payload of scripts/package/build-payload.sh as rpm, for one distribution of
# scripts/package/distros.txt: podman, and the noarch podman-docker and podmansh. Run as root
# in the build container, where rpmbuild is.
#
# The version is the release version with its +rR (6.2.0+r12), the revision R is the release
# counter of every file name, and everything else the spec says comes from the row of the
# distribution, so a distribution is a line of a table and not a branch of this script.
#
# Usage: build-rpm.sh <payload-dir> <id> <version> <out-dir>
#   <version> is X.Y.Z+rR, always with the +rR

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
distros="$here/../distros.sh"
payload="$(cd "${1:?payload dir}" && pwd)"
id="${2:?distribution id}"
version="${3:?version X.Y.Z+rR}"
out="$(mkdir -p "${4:?output dir}" && cd "$4" && pwd)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+r([0-9]+)$ ]] || { echo "bad version, expected X.Y.Z+rR: $version" >&2; exit 1; }
revision="${BASH_REMATCH[1]}"
[ "$(bash "$distros" field "$id" format)" = rpm ] || { echo "$id is not an rpm distribution" >&2; exit 1; }
field() { bash "$distros" field "$id" "$1"; }
[ -f "$payload/facts.env" ] || { echo "no facts.env in $payload: the payload was not built" >&2; exit 1; }
# shellcheck disable=SC1091
. "$payload/facts.env"
for v in NETAVARK_VERSION AARDVARK_VERSION COMMON_VERSION; do
	[ -n "${!v:-}" ] || { echo "facts.env has no $v" >&2; exit 1; }
done

# RHEL numbers its containers-common with Podman's own version; every other distribution with
# upstream's, which the payload says.
case "$(field cc_scheme)" in
	podman) cc_version="$version" ;;
	*) cc_version="$COMMON_VERSION" ;;
esac

top="$(mktemp -d)"
trap 'rm -rf "$top"' EXIT
mkdir -p "$top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "$here/podman.spec" "$top/SPECS/podman.spec"
rpmbuild -bb \
	--define "_topdir $top" \
	--define "gl_id $id" \
	--define "gl_family $(field family)" \
	--define "gl_epoch $(field epoch)" \
	--define "gl_version $version" \
	--define "gl_release $revision" \
	--define "gl_payload $payload" \
	--define "gl_netavark $NETAVARK_VERSION" \
	--define "gl_aardvark $AARDVARK_VERSION" \
	--define "gl_nv_epoch $(field nv_epoch)" \
	--define "gl_cc_epoch $(field cc_epoch)" \
	--define "gl_cc_version $cc_version" \
	--define "gl_passt_min $(field passt_min)" \
	"$top/SPECS/podman.spec" >&2
find "$top/RPMS" -name '*.rpm' -exec cp {} "$out/" \;
ls "$out"/*.rpm
