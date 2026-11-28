#!/usr/bin/env bash
#
# The record of a release, components.txt, its list of hashes, SHA256SUMS, and the check of everything a release signs.
#
# components.txt is what the plan and the watchdog compare with upstream, so it is signed with the release keys like the
# packages are, in the job that holds them, and read only after its signature verifies (scripts/upstream/read-released.sh).
# Its first line names the release it belongs to, so a signed record cannot be put on another release.
#
# What a release signs is the two .deb, every rpm of scripts/release/rpm/names.sh, components.txt and SHA256SUMS: `list`
# is the one place that says it, and the job that signs, the check of the set and the release read it from here.
#
#   components <out>                                  writes the record from TAG, PODMAN, NETAVARK, AARDVARK and RECIPE,
#                                                     with the rpm distributions of the release (the line `ids`) and the
#                                                     recipe of scripts/package (the line `recipe-package`)
#   sums <dir>                                        writes <dir>/SHA256SUMS, the sha256 of every other file of the list,
#                                                     all of which have to be in <dir>
#   list                                              the files that are signed, one per line
#   assets <true|false>                               the names a release attaches: every file of the list with its
#                                                     signature, and the second one when the flag is true
#   verify <dir> <ed25519> <mldsa-keys> <true|false> <venv>
#                                                     verifies every file of the list in <dir> against the keys given, the
#                                                     second signature when the flag is true, that the record is of TAG and
#                                                     names its distributions, and that SHA256SUMS is the one of the files.
#                                                     <venv> is the environment that has the signing library; its
#                                                     interpreter is started isolated.
#
# Usage: signed-set.sh components <out> | sums <dir> | list | assets <true|false>
#        signed-set.sh verify <dir> <ed25519.b64> <mldsa65.b64> <true|false> <venv>
# Exit 0 when done, 1 when something is refused, 2 for a usage error.

set -euo pipefail

usage() { echo "usage: signed-set.sh components <out> | sums <dir> | list | assets <true|false> | verify <dir> <ed25519.b64> <mldsa65.b64> <true|false> <venv>" >&2; exit 2; }
tag="${TAG:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || { echo "the tag '$tag' is not vX.Y.Z or vX.Y.Z+rN" >&2; exit 1; }
version="${tag#v}"
here="$(cd "$(dirname "$0")/../.." && pwd)"

# signed_files: everything that is signed, in the order it is listed, SHA256SUMS last. Printed only when it is whole.
signed_files() {
	local rpms
	rpms="$(bash "$here/scripts/release/rpm/names.sh" release "$version")" || { echo "the rpm packages of $tag cannot be named" >&2; return 1; }
	printf 'podman_%s_amd64.deb\npodman_%s_arm64.deb\n%s\ncomponents.txt\nSHA256SUMS\n' "$version" "$version" "$rpms"
}

# ids_line: the line of the record that names the rpm distributions of the release
ids_line() {
	local ids
	ids="$(bash "$here/scripts/package/distros.sh" ids rpm)" || { echo "the rpm rows of distros.txt cannot be read" >&2; return 1; }
	[ -n "$ids" ] || { echo "distros.txt has no rpm row" >&2; return 1; }
	printf 'ids %s\n' "$(tr '\n' ' ' <<< "$ids" | sed 's/ $//')"
}

# sums_of <dir>: the sha256 of every signed file but SHA256SUMS, in the format `sha256sum -c` reads
sums_of() {
	local files name
	files="$(signed_files)" || return 1
	while IFS= read -r name; do
		[ "$name" != SHA256SUMS ] || continue
		[ -f "$1/$name" ] && [ ! -L "$1/$name" ] || { echo "$name is not there to be hashed" >&2; return 1; }
		(cd "$1" && sha256sum -- "$name") || { echo "$name cannot be hashed" >&2; return 1; }
	done <<< "$files"
}

case "${1:-}" in
	components)
		[ "$#" -eq 2 ] || usage
		for name in PODMAN NETAVARK AARDVARK RECIPE; do
			value="${!name:-}"
			[[ "$value" =~ ^[A-Za-z0-9.+_-]+$ ]] || { echo "$name is '$value', not a tag or a digest: no record is written" >&2; exit 1; }
		done
		record_ids="$(ids_line)" || exit 1
		recipe_package="$(bash "$here/scripts/build/recipe-id.sh" "$here/scripts/package")" \
			|| { echo "the recipe of scripts/package cannot be read: no record is written" >&2; exit 1; }
		printf 'release %s\npodman %s\nnetavark %s\naardvark-dns %s\nrecipe %s\n%s\nrecipe-package %s\n' \
			"$tag" "$PODMAN" "$NETAVARK" "$AARDVARK" "$RECIPE" "$record_ids" "$recipe_package" > "$2" ;;
	sums)
		[ "$#" -eq 2 ] || usage
		sums="$(sums_of "$2")" || { echo "SHA256SUMS is not written without every file of the release" >&2; exit 1; }
		printf '%s\n' "$sums" > "$2/SHA256SUMS" ;;
	list)
		[ "$#" -eq 1 ] || usage
		signed_files ;;
	assets)
		[ "$#" -eq 2 ] || usage
		case "$2" in true | false) ;; *) echo "the second-signature flag is true or false, not '$2'" >&2; exit 1 ;; esac
		files="$(signed_files)" || exit 1
		while IFS= read -r name; do
			printf '%s\n%s.sig\n' "$name" "$name"
			if [ "$2" = true ]; then printf '%s.mldsa65.sig\n' "$name"; fi
		done <<< "$files" ;;
	verify)
		[ "$#" -eq 6 ] || usage
		dir="$2" ed25519="$3" mldsa="$4" require="$5" py="$6/bin/python"
		case "$require" in true | false) ;; *) echo "the second-signature flag is true or false, not '$require'" >&2; exit 1 ;; esac
		[ -x "$py" ] || { echo "$py is not there: the environment with the signing library is missing" >&2; exit 1; }
		required=()
		if [ "$require" = true ]; then required=(--require-mldsa); fi
		listed="$(signed_files)" || exit 1
		while IFS= read -r name; do
			file="$dir/$name"
			"$py" -I "$here/.github/scripts/release/verify-sig.py" "$file" "$file.sig" "$ed25519" \
				--mldsa-sig "$file.mldsa65.sig" --mldsa-keys "$mldsa" "${required[@]}" < /dev/null \
				|| { echo "the signature of ${file##*/} does not verify" >&2; exit 1; }
		done <<< "$listed"
		if [ "$(grep -c "^release " "$dir/components.txt")" != 1 ] || ! grep -qxF "release $tag" "$dir/components.txt"; then
			echo "components.txt does not name the release $tag, once" >&2
			exit 1
		fi
		want_ids="$(ids_line)" || exit 1
		if [ "$(grep -c "^ids " "$dir/components.txt")" != 1 ] || ! grep -qxF "$want_ids" "$dir/components.txt"; then
			echo "components.txt does not name the distributions of the release, '$want_ids', once" >&2
			exit 1
		fi
		sums="$(sums_of "$dir")" || exit 1
		[ "$(cat "$dir/SHA256SUMS")" = "$sums" ] || { echo "SHA256SUMS is not the hashes of the files of the release" >&2; exit 1; } ;;
	*) usage ;;
esac
