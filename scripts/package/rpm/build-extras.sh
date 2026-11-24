#!/usr/bin/env bash
#
# Compile and package the dependencies a distribution takes beside podman (the `extras` of its row
# of distros.txt) from the sources scripts/package/rpm/fetch-extras.sh verified, inside the build
# container, as root. Each one becomes an rpm with the Name of the distribution's own package, the
# version of extras.txt and the release R.glyndor.<id>, with the epoch the distribution uses.
#
# Usage: build-extras.sh <id> <revision R> <sources-dir> <out-dir>
# GLYNDOR_EXTRAS_FILE moves the table of pins, for tests.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="${1:?distribution id}"
revision="${2:?revision}"
src="$(cd "${3:?sources dir}" && pwd)"
out="$(mkdir -p "${4:?output dir}" && cd "$4" && pwd)"
table="${GLYNDOR_EXTRAS_FILE:-$here/../extras.txt}"
[[ "$revision" =~ ^[0-9]+$ ]] || { echo "the revision is a number: $revision" >&2; exit 1; }

wanted="$(bash "$here/../distros.sh" field "$id" extras)"
[ -n "$wanted" ] || { echo "$id takes no extras"; exit 0; }
family="$(bash "$here/../distros.sh" field "$id" family)"
case "$family" in
	suse) install=(zypper --non-interactive install --no-recommends) ;;
	*) install=(dnf install -y --setopt=install_weak_deps=False) ;;
esac
# What the four need, under the names of each family; a name the family does not have is skipped,
# and the build says what it lacks when it fails.
for pkg in gcc make autoconf automake libtool git-core pkgconf-pkg-config libcap-devel yajl-devel libyajl-devel \
	json-c-devel libjson-c-devel glib2-devel libseccomp-devel systemd-devel glibc-static glibc-devel-static python3 \
	rpm-build; do
	"${install[@]}" "$pkg" > /dev/null 2>&1 || echo "no $pkg here" >&2
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
jobs="$(nproc)"

for name in ${wanted//,/ }; do
	row="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$table" | awk -F'|' -v n="$name" '$1 == n' || true)"
	[ -n "$row" ] || { echo "$name is not in $table" >&2; exit 1; }
	IFS='|' read -r _ version epoch kind _ <<< "$row"
	tree="$work/$name-tree"
	build="$work/$name-build"
	mkdir -p "$tree" "$build"
	if [ "$kind" = tarball ]; then
		tar -C "$build" --strip-components=1 -xf "$src/$name"/src.tar.* || { echo "cannot unpack the source of $name" >&2; exit 1; }
	else
		cp -a "$src/$name/tree/." "$build/"
	fi
	(
		cd "$build"
		case "$name" in
			crun)
				./configure --prefix=/usr
				make -j"$jobs"
				make DESTDIR="$tree" install ;;
			catatonit)
				autoreconf -fi
				./configure --prefix=/usr
				make -j"$jobs"
				make DESTDIR="$tree" install
				# Where the distributions put it, and where Podman looks for its helpers.
				install -d "$tree/usr/libexec/catatonit" "$tree/usr/libexec/podman"
				mv "$tree/usr/bin/catatonit" "$tree/usr/libexec/catatonit/catatonit"
				ln -s ../catatonit/catatonit "$tree/usr/libexec/podman/catatonit" ;;
			conmon)
				make PREFIX=/usr
				make PREFIX=/usr DESTDIR="$tree" install ;;
			passt)
				make prefix=/usr
				make prefix=/usr DESTDIR="$tree" install
				ln -sf passt "$tree/usr/bin/pasta" ;;
			*) echo "no recipe for $name" >&2; exit 1 ;;
		esac
	) >&2
	find "$tree" \( -name '*.la' -o -name '*.a' \) -delete
	find "$tree" -type f -print0 | while IFS= read -r -d '' f; do
		if file -b "$f" | grep -q '^ELF'; then strip --strip-unneeded "$f"; fi
	done
	top="$work/$name-rpm"
	mkdir -p "$top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	cp "$here/extra.spec" "$top/SPECS/extra.spec"
	rpmbuild -bb \
		--define "_topdir $top" --define "gl_name $name" --define "gl_version $version" --define "gl_epoch $epoch" \
		--define "gl_release $revision" --define "gl_id $id" --define "gl_tree $tree" "$top/SPECS/extra.spec" >&2
	find "$top/RPMS" -name '*.rpm' -exec cp {} "$out/" \;
done
ls "$out"/*.rpm
