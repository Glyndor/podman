#!/usr/bin/env bash
#
# The record of a release, components.txt, and the check of everything a release signs.
#
# components.txt is what the plan and the watchdog compare with upstream, so it is signed with the release keys like the
# packages are, in the job that holds them, and read only after its signature verifies (scripts/upstream/read-released.sh).
# Its first line names the release it belongs to, so a signed record cannot be put on another release.
#
#   components <out>                                  writes the record from TAG, PODMAN, NETAVARK, AARDVARK and RECIPE
#   verify <dir> <ed25519> <mldsa-keys> <true|false> <venv>
#                                                     verifies both packages and the record in <dir> against the keys
#                                                     given, the second signature when the flag is true, and that the
#                                                     record is of TAG. <venv> is the environment that has the signing
#                                                     library; its interpreter is started isolated.
#
# Usage: signed-set.sh components <out> | signed-set.sh verify <dir> <ed25519.b64> <mldsa65.b64> <true|false> <venv>
# Exit 0 when done, 1 when something is refused, 2 for a usage error.

set -euo pipefail

usage() { echo "usage: signed-set.sh components <out> | verify <dir> <ed25519.b64> <mldsa65.b64> <true|false> <venv>" >&2; exit 2; }
tag="${TAG:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || { echo "the tag '$tag' is not vX.Y.Z or vX.Y.Z+rN" >&2; exit 1; }

case "${1:-}" in
	components)
		[ "$#" -eq 2 ] || usage
		for name in PODMAN NETAVARK AARDVARK RECIPE; do
			value="${!name:-}"
			[[ "$value" =~ ^[A-Za-z0-9.+_-]+$ ]] || { echo "$name is '$value', not a tag or a digest: no record is written" >&2; exit 1; }
		done
		printf 'release %s\npodman %s\nnetavark %s\naardvark-dns %s\nrecipe %s\n' \
			"$tag" "$PODMAN" "$NETAVARK" "$AARDVARK" "$RECIPE" > "$2" ;;
	verify)
		[ "$#" -eq 6 ] || usage
		dir="$2" ed25519="$3" mldsa="$4" require="$5" py="$6/bin/python"
		case "$require" in true | false) ;; *) echo "the second-signature flag is true or false, not '$require'" >&2; exit 1 ;; esac
		[ -x "$py" ] || { echo "$py is not there: the environment with the signing library is missing" >&2; exit 1; }
		here="$(cd "$(dirname "$0")/../.." && pwd)"
		required=()
		if [ "$require" = true ]; then required=(--require-mldsa); fi
		version="${tag#v}"
		for file in "$dir/podman_${version}_amd64.deb" "$dir/podman_${version}_arm64.deb" "$dir/components.txt"; do
			"$py" -I "$here/.github/scripts/release/verify-sig.py" "$file" "$file.sig" "$ed25519" \
				--mldsa-sig "$file.mldsa65.sig" --mldsa-keys "$mldsa" "${required[@]}" \
				|| { echo "the signature of ${file##*/} does not verify" >&2; exit 1; }
		done
		if [ "$(grep -c "^release " "$dir/components.txt")" != 1 ] || ! grep -qxF "release $tag" "$dir/components.txt"; then
			echo "components.txt does not name the release $tag, once" >&2
			exit 1
		fi ;;
	*) usage ;;
esac
