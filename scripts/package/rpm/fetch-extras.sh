#!/usr/bin/env bash
#
# Fetch and verify the sources of the dependencies a distribution takes beside podman, on the
# runner, before any of them is compiled: a tarball whose signature is made by the pinned key, or
# a tag that resolves to the pinned commit (scripts/package/extras.txt says which each one is).
# Anything that does not verify stops the job, and nothing is compiled from it.
#
# Each source ends in <dest>/<name>/ : a tarball as src.tar.<ext>, a clone as a tree without .git.
#
# Usage: fetch-extras.sh <id> <dest>
# GLYNDOR_EXTRAS_FILE and GLYNDOR_KEYS_DIR move the table and the keys, for tests.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="${1:?distribution id}"
dest="$(mkdir -p "${2:?destination}" && cd "$2" && pwd)"
table="${GLYNDOR_EXTRAS_FILE:-$here/../extras.txt}"
keys="${GLYNDOR_KEYS_DIR:-$here/../../../keyring/extras}"

wanted="$(bash "$here/../distros.sh" field "$id" extras)"
gnupg="$(mktemp -d)"
trap 'rm -rf "$gnupg"' EXIT
export GNUPGHOME="$gnupg"

for name in ${wanted//,/ }; do
	row="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$table" | awk -F'|' -v n="$name" '$1 == n' || true)"
	[ -n "$row" ] || { echo "$name is not in $table" >&2; exit 1; }
	IFS='|' read -r _ version _ kind source pin keyfile fingerprint <<< "$row"
	out="$dest/$name"
	rm -rf "$out"
	mkdir -p "$out"
	case "$kind" in
		tarball)
			case "$source" in *.tar.gz) ext=tar.gz ;; *.tar.xz) ext=tar.xz ;; *) echo "$name: $source is not a tarball" >&2; exit 1 ;; esac
			curl -fsSL --retry 3 -o "$out/src.$ext" "$source" || { echo "cannot fetch $source" >&2; exit 1; }
			curl -fsSL --retry 3 -o "$out/src.$ext.asc" "$source.asc" || { echo "cannot fetch the signature of $source" >&2; exit 1; }
			[ "$(sha256sum "$out/src.$ext" | cut -d' ' -f1)" = "${pin#sha256:}" ] \
				|| { echo "$name: the tarball is not the one pinned in extras.txt" >&2; exit 1; }
			gpg --batch --quiet --import "$keys/$keyfile" || { echo "cannot import $keyfile" >&2; exit 1; }
			status="$(gpg --batch --status-fd 1 --verify "$out/src.$ext.asc" "$out/src.$ext" 2> /dev/null)" || status=""
			grep -q "^\[GNUPG:\] VALIDSIG .* $fingerprint\$" <<< "$status" \
				|| { echo "$name: the signature is not a good one made by $fingerprint" >&2; exit 1; }
			echo "verified $name $version: tarball signed by $fingerprint" ;;
		git)
			tag="${pin%%=*}"
			commit="${pin#*=}"
			# Cloned without a checkout and without --branch: --branch prefers a branch to a tag of the same
			# name, so a remote with a branch called like the tag would have its branch compiled while the
			# tag was the one checked. The tag is resolved by its full ref, the commit it names is the one
			# pinned, and what is extracted is that commit, which is read back from the tree itself.
			git clone --quiet --no-checkout "$source" "$out/tree" || { echo "cannot clone $source at $tag" >&2; exit 1; }
			if git -C "$out/tree" rev-parse --verify --quiet "refs/remotes/origin/$tag" > /dev/null; then
				echo "$name: the remote has a branch called $tag as well as the tag, and it is not known which is meant" >&2
				exit 1
			fi
			[ "$(git -C "$out/tree" rev-parse "refs/tags/$tag^{commit}")" = "$commit" ] \
				|| { echo "$name: the tag $tag is not at the commit pinned in extras.txt" >&2; exit 1; }
			# Plain commands: a failure of either stops the script (set -e) before the tree is used.
			git -C "$out/tree" checkout --quiet --detach "$commit"
			test "$(git -C "$out/tree" rev-parse HEAD)" = "$commit"
			rm -rf "$out/tree/.git"
			echo "verified $name $version: $tag is $commit (the project signs neither; the commit is pinned)" ;;
		*) echo "$name: unknown kind $kind" >&2; exit 1 ;;
	esac
done
