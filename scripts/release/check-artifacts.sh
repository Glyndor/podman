#!/usr/bin/env bash
#
# Say whether what a release job downloaded is exactly what the release is made of, before
# anything that holds a key or can publish touches it. Artifacts are produced by jobs that run
# third-party code, so a download is not a package until it has been counted, named and read:
# a file of more, a file of another version or architecture, a link, a script that would be run
# by an interpreter started in that directory, all stop here.
#
# The names come from the tag the plan verified and from nothing in the download. Equality with
# that list is the rule; a pattern such as podman_*.deb is not.
#
#   built  <tag> <in-dir> <out-dir>   <in-dir> holds exactly deb-amd64/ and deb-arm64/, each with
#                                     its one podman_<V>_<arch>.deb: regular files, under the size
#                                     cap, whose control file says package podman, version <V>
#                                     and that architecture. They are copied flat into <out-dir>,
#                                     which must be empty or absent.
#   signed <tag> <dir> <mldsa>        <dir> holds exactly the two packages and components.txt, a
#                                     64-byte Ed25519 signature beside each, and, when <mldsa> is
#                                     true, a 3309-byte ML-DSA-65 signature beside each; when it is
#                                     false, none.
#
# Usage: check-artifacts.sh built <tag> <in-dir> <out-dir>
#        check-artifacts.sh signed <tag> <dir> <true|false>
# Exit 0 when the set is exact, 1 when it is not, 2 for a usage error.

set -euo pipefail

mode="${1:-}"
tag="${2:-}"
[ "$#" -ge 3 ] || { echo "usage: check-artifacts.sh built <tag> <in-dir> <out-dir> | signed <tag> <dir> <true|false>" >&2; exit 2; }
dir="$3"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || { echo "the tag '$tag' is not vX.Y.Z or vX.Y.Z+rN" >&2; exit 1; }
version="${tag#v}"
archs=(amd64 arm64)
max_deb=$((300 * 1024 * 1024))
max_record=4096
[ -d "$dir" ] && [ ! -L "$dir" ] || { echo "$dir is not a directory" >&2; exit 1; }

# listing <dir>: every entry below it with its type, as `<path> <type>`, in a fixed order.
# Types are find's: d directory, f regular file, l link, anything else is not a package either.
listing() { (cd "$1" && find . -mindepth 1 -printf '%P %y\n' | LC_ALL=C sort); }

size_of() { stat -c %s -- "$1"; }

case "$mode" in
	built)
		[ "$#" -eq 4 ] || { echo "usage: check-artifacts.sh built <tag> <in-dir> <out-dir>" >&2; exit 2; }
		out="$4"
		want=""
		for a in "${archs[@]}"; do
			want+="deb-$a d"$'\n'"deb-$a/podman_${version}_$a.deb f"$'\n'
		done
		want="$(printf '%s' "$want" | LC_ALL=C sort)"
		got="$(listing "$dir")"
		[ "$got" = "$want" ] || { printf 'the download is not exactly the expected set.\nexpected:\n%s\nfound:\n%s\n' "$want" "$got" >&2; exit 1; }
		if [ -e "$out" ]; then
			[ -d "$out" ] && [ ! -L "$out" ] && [ -z "$(ls -A "$out")" ] || { echo "$out is not an empty directory" >&2; exit 1; }
		fi
		mkdir -p "$out"
		for a in "${archs[@]}"; do
			deb="$dir/deb-$a/podman_${version}_$a.deb"
			[ "$(size_of "$deb")" -le "$max_deb" ] || { echo "the downloaded package $deb is over the size cap of $max_deb bytes" >&2; exit 1; }
			control="$(dpkg-deb -f "$deb" Package Version Architecture)" || { echo "$deb has no readable control file" >&2; exit 1; }
			[ "$control" = "$(printf 'Package: podman\nVersion: %s\nArchitecture: %s' "$version" "$a")" ] \
				|| { printf '%s says\n%s\nand not podman %s %s\n' "$deb" "$control" "$version" "$a" >&2; exit 1; }
			install -m 0644 -- "$deb" "$out/podman_${version}_$a.deb"
		done ;;
	signed)
		[ "$#" -eq 4 ] || { echo "usage: check-artifacts.sh signed <tag> <dir> <true|false>" >&2; exit 2; }
		mldsa="$4"
		case "$mldsa" in true | false) ;; *) echo "the second-signature flag is true or false, not '$mldsa'" >&2; exit 1 ;; esac
		files=(components.txt)
		for a in "${archs[@]}"; do files+=("podman_${version}_$a.deb"); done
		want=""
		for name in "${files[@]}"; do
			want+="$name f"$'\n'"$name.sig f"$'\n'
			if [ "$mldsa" = true ]; then want+="$name.mldsa65.sig f"$'\n'; fi
		done
		want="$(printf '%s' "$want" | LC_ALL=C sort)"
		got="$(listing "$dir")"
		[ "$got" = "$want" ] || { printf 'the signed set is not exactly the expected one.\nexpected:\n%s\nfound:\n%s\n' "$want" "$got" >&2; exit 1; }
		[ "$(size_of "$dir/components.txt")" -le "$max_record" ] || { echo "components.txt is over the size cap of $max_record bytes" >&2; exit 1; }
		for name in "${files[@]}"; do
			file="$dir/$name"
			[ "$(size_of "$file")" -le "$max_deb" ] || { echo "the signed package $file is over the size cap of $max_deb bytes" >&2; exit 1; }
			[ "$(size_of "$file.sig")" -eq 64 ] || { echo "$file.sig is not 64 bytes, the size of an Ed25519 signature" >&2; exit 1; }
			if [ "$mldsa" = true ]; then
				[ "$(size_of "$file.mldsa65.sig")" -eq 3309 ] || { echo "$file.mldsa65.sig is not 3309 bytes, the size of an ML-DSA-65 signature" >&2; exit 1; }
			fi
		done ;;
	*) echo "usage: check-artifacts.sh built <tag> <in-dir> <out-dir> | signed <tag> <dir> <true|false>" >&2; exit 2 ;;
esac
echo "the set is exactly what $tag is made of ($mode)"
