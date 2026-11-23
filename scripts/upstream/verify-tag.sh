#!/usr/bin/env bash
#
# Verify that an upstream tag is an annotated tag signed by a key Podman's own
# maintainers authorise (the keys in keyring/podman/, copied from
# github.com/containers/release-keys). Fail closed on anything else: unsigned,
# bad signature, unknown key, expired or revoked key.
#
# Prints the commit the tag points to, for the build to check out.
#
# Usage: verify-tag.sh <source-dir> <tag> [keys-dir]

set -euo pipefail

src="${1:?source dir}"
tag="${2:?tag}"
keys="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/keyring/podman}"

[ "$(git -C "$src" cat-file -t "refs/tags/$tag")" = tag ] \
	|| { echo "$tag is not an annotated tag" >&2; exit 1; }

# The signature covers the tag object, whose own header names the tag. A ref that
# is renamed onto an older signed object would still verify, so the name inside
# the object has to be the one that was asked for.
named="$(git -C "$src" cat-file -p "refs/tags/$tag" | sed -n 's/^tag //p' | head -n 1)"
[ "$named" = "$tag" ] \
	|| { echo "ref $tag points at a signed tag object named '$named'" >&2; exit 1; }

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

shopt -s nullglob
files=("$keys"/*.asc)
[ ${#files[@]} -gt 0 ] || { echo "no keys under $keys" >&2; exit 1; }
# gpg's own message stays visible, and so does its status: a key file that does not
# import leaves no allowed key, and the log has to say which step stopped and why.
rc=0
gpg --batch --quiet --import "${files[@]}" || rc=$?
[ "$rc" -eq 0 ] || { echo "could not import the keys under $keys" >&2; exit "$rc"; }

status="$(git -C "$src" verify-tag --raw "refs/tags/$tag" 2>&1)" || true

# The verdict is the one fetch-extras.sh gives a tarball: a good signature, and none of the others beside it (see
# gpg-verdict.sh for why both rules are needed).
# shellcheck source=scripts/upstream/gpg-verdict.sh
. "$(dirname "${BASH_SOURCE[0]}")/gpg-verdict.sh"
if ! reason="$(gpg_verdict "$status")"; then
	if [ "$reason" = "no good signature" ]; then
		echo "tag $tag has no good signature" >&2
	else
		echo "tag $tag rejected: $reason" >&2
	fi
	exit 1
fi

git -C "$src" rev-parse "refs/tags/$tag^{commit}"
