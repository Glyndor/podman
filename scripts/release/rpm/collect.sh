#!/usr/bin/env bash
#
# Turn the artifacts of the build jobs into the one set of rpm packages a release carries, and say
# what that set is made of in one hash.
#
#   gather <version> <prefix> <legs-json> <legs-dir> <set-dir>
#       <legs-dir> holds exactly one directory <prefix>-<id>-<arch> for every leg, each with exactly
#       the packages of that leg, regular files whose sha256 is the one its build job reported
#       (<legs-json>, see legs.sh). The packages of the release (names.sh release, the noarch ones
#       from the x86_64 leg) are copied into <set-dir>, which must be empty or absent.
#   digest <version> <set-dir>
#       <set-dir> holds exactly the packages of the release, regular files. Prints the sha256 of the
#       `sha256sum` lines of those files in the order of names.sh, so that the job that signs can
#       require the set it downloaded to be the one that was gathered.
#
# Usage: collect.sh gather <version> <prefix> <legs-json> <legs-dir> <set-dir> | digest <version> <set-dir>
# Exit 0 when the set is exact, 1 when it is not, 2 for a usage error.

set -euo pipefail

usage() { echo "usage: collect.sh gather <version> <prefix> <legs-json> <legs-dir> <set-dir> | digest <version> <set-dir>" >&2; exit 2; }
die() { echo "::error::$*; refusing the rpm packages." >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
max_rpm=$((300 * 1024 * 1024))

# listing <dir>: every entry below it with its type, as `<path> <type>`, in a fixed order
listing() { (cd "$1" && find . -mindepth 1 -printf '%P %y\n' | LC_ALL=C sort); }
sha_of() { local sum; sum="$(sha256sum -- "$1")"; printf '%s' "${sum%% *}"; }

case "${1:-}" in
	gather)
		[ "$#" -eq 6 ] || usage
		version="$2" prefix="$3" legs_json="$4" dir="$5" set="$6"
		case "$prefix" in rpm | rpmcheck) ;; *) die "the artifacts are called rpm- or rpmcheck-, not '$prefix-'" ;; esac
		[ -d "$dir" ] && [ ! -L "$dir" ] || die "$dir is not a directory"
		legs="$(bash "$here/names.sh" legs)" || die "the legs of distros.txt cannot be read"
		release="$(bash "$here/names.sh" release "$version")" || die "the packages of $version cannot be named"
		# what has to be on the disk: the directory of every leg with its files, and nothing else
		want=""
		while read -r id arch; do
			leg="$prefix-$id-$arch"
			files="$(bash "$here/names.sh" leg "$version" "$id" "$arch")" || die "the packages of $id $arch cannot be named"
			want+="$leg d"$'\n'
			while IFS= read -r f; do want+="$leg/$f f"$'\n'; done <<< "$files"
		done <<< "$legs"
		want="$(printf '%s' "$want" | LC_ALL=C sort)"
		got="$(listing "$dir")"
		[ "$got" = "$want" ] || { printf 'the download is not exactly the packages of the legs.\nexpected:\n%s\nfound:\n%s\n' "$want" "$got" >&2; die "the download is not the expected set"; }
		# every file is the one its build job hashed, and the report names every file and no other
		while read -r id arch; do
			leg="$prefix-$id-$arch"
			report="$(jq -r --arg k "${id}_$arch" '.[$k] | if type == "string" then . else error("not a string") end' <<< "$legs_json")" \
				|| die "the leg ${id}_$arch reported nothing"
			read -r _ _ hashes <<< "$report" || true
			reported="$(tr ' ' '\n' <<< "${hashes:-}" | sed '/^$/d; s/=.*//' | LC_ALL=C sort)"
			files="$(bash "$here/names.sh" leg "$version" "$id" "$arch" | LC_ALL=C sort)" || die "the packages of $id $arch cannot be named"
			[ "$reported" = "$files" ] || die "the leg ${id}_$arch did not report one hash for each of its packages and no other"
			for pair in $hashes; do
				name="${pair%%=*}" want_sum="${pair#*=}"
				[[ "$want_sum" =~ ^[0-9a-f]{64}$ ]] || die "the leg ${id}_$arch reported the sha256 '$want_sum' for $name, not a sha256"
				[ "$(stat -c %s -- "$dir/$leg/$name")" -le "$max_rpm" ] || die "$name is over the size cap of $max_rpm bytes"
				got_sum="$(sha_of "$dir/$leg/$name")"
				[ "$got_sum" = "$want_sum" ] || die "$name of ${id}_$arch is $got_sum, and the build hashed $want_sum before it ran"
			done
		done <<< "$legs"
		if [ -e "$set" ]; then
			[ -d "$set" ] && [ ! -L "$set" ] && [ -z "$(ls -A "$set")" ] || die "$set is not an empty directory"
		fi
		mkdir -p "$set"
		while IFS= read -r name; do
			rest="${name%.rpm}"
			arch="${rest##*.}"
			[ "$arch" != noarch ] || arch=x86_64
			rest="${rest%.*}"
			id="${rest##*.}"
			install -m 0644 -- "$dir/$prefix-$id-$arch/$name" "$set/$name"
		done <<< "$release"
		echo "gathered the packages of $version" ;;
	digest)
		[ "$#" -eq 3 ] || usage
		version="$2" set="$3"
		[ -d "$set" ] && [ ! -L "$set" ] || die "$set is not a directory"
		release="$(bash "$here/names.sh" release "$version")" || die "the packages of $version cannot be named"
		want="$(awk '{print $0 " f"}' <<< "$release" | LC_ALL=C sort)"
		got="$(listing "$set")"
		[ "$got" = "$want" ] || { printf 'the set is not exactly the packages of the release.\nexpected:\n%s\nfound:\n%s\n' "$want" "$got" >&2; die "the set of $version is not the expected one"; }
		lines=""
		while IFS= read -r name; do
			sum="$(sha_of "$set/$name")" || die "$name cannot be hashed"
			lines+="$sum  $name"$'\n'
		done <<< "$release"
		sum="$(printf '%s' "$lines" | sha256sum)"
		printf '%s\n' "${sum%% *}" ;;
	*) usage ;;
esac
