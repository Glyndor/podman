#!/usr/bin/env bash
#
# Verify that an upstream tag is an annotated tag signed by a key Podman's own
# maintainers authorise (the keys in keyring/podman/, copied from
# github.com/containers/release-keys). Fail closed on anything else: unsigned,
# bad signature, unknown key, expired or revoked key, and a signature of another format.
#
# The verdict is not git's alone. git picks the program that checks a tag from the header of its signature, so a tag
# signed with an X.509 certificate or an SSH key would never reach the keyring built here, and the configuration of
# the user or the system can name another program for OpenPGP too. So the tag has to carry an OpenPGP signature, git
# is run with no configuration but the one given here, with this gpg and the other two formats pointed at a program
# that fails, the exit status of git is read, and every signature the status reports has to be made by a primary key
# of those imported from the keys directory.
#
# Prints the commit the tag points to, for the build to check out.
#
# Usage: verify-tag.sh <source-dir> <tag> [keys-dir]

set -euo pipefail

src="${1:?source dir}"
tag="${2:?tag}"
keys="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/keyring/podman}"

# No configuration of the user or the system reaches git here: it could name another program for a signature.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG GIT_DIR
# shellcheck source=scripts/upstream/gpg-verdict.sh
. "$(dirname "${BASH_SOURCE[0]}")/gpg-verdict.sh"

[ "$(git -C "$src" cat-file -t "refs/tags/$tag")" = tag ] \
	|| { echo "$tag is not an annotated tag" >&2; exit 1; }

# The signature covers the tag object, whose own header names the tag. A ref that
# is renamed onto an older signed object would still verify, so the name inside
# the object has to be the one that was asked for.
named="$(git -C "$src" cat-file -p "refs/tags/$tag" | sed -n 's/^tag //p' | head -n 1)"
[ "$named" = "$tag" ] \
	|| { echo "ref $tag points at a signed tag object named '$named'" >&2; exit 1; }

# The signature has to be an OpenPGP one. git finds it at the first line of the message that starts a known kind, and
# decides the program from that line; so the first such line has to be the one of OpenPGP, and there is no other kind.
signature_start="$(git -C "$src" cat-file tag "refs/tags/$tag" | sed -n -E '/^-----BEGIN (PGP SIGNATURE|PGP MESSAGE|SIGNED MESSAGE|SSH SIGNATURE)-----$/{p;q}')"
case "$signature_start" in
	"-----BEGIN PGP SIGNATURE-----") ;;
	"") echo "tag $tag has no good signature" >&2; exit 1 ;;
	*) echo "tag $tag is not signed with OpenPGP: it starts its signature with '$signature_start'" >&2; exit 1 ;;
esac

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

# What the keys imported are: the primary fingerprints a signature has to name, whatever subkey made it.
mapfile -t pinned < <(gpg_primary_fingerprints)
[ "${#pinned[@]}" -gt 0 ] || { echo "the keys under $keys hold no key" >&2; exit 1; }

# git runs this gpg, in this keyring, with no other format and no minimum of trust: the trust of a key is not what
# decides here (the keys imported are not signed by anyone), the verdict below is.
gpg_program="$(command -v gpg)"
rc=0
status="$(git -C "$src" -c gpg.format=openpgp -c "gpg.openpgp.program=$gpg_program" -c gpg.x509.program=/bin/false \
	-c gpg.ssh.program=/bin/false -c gpg.minTrustLevel=undefined verify-tag --raw "refs/tags/$tag" 2>&1)" || rc=$?

gpg_has_status "$status" || { echo "tag $tag: git could not check the signature (exit $rc): $status" >&2; exit 1; }
# The verdict is the one fetch-extras.sh gives a tarball: a good signature, and none of the others beside it (see
# gpg-verdict.sh for why both rules are needed), all of them by the keys pinned.
if ! reason="$(gpg_verdict "$status" "${pinned[@]}")"; then
	if [ "$reason" = "no good signature" ]; then
		echo "tag $tag has no good signature" >&2
	else
		echo "tag $tag rejected: $reason" >&2
	fi
	exit 1
fi
[ "$rc" -eq 0 ] || { echo "tag $tag rejected: git verify-tag exited $rc" >&2; exit 1; }

git -C "$src" rev-parse "refs/tags/$tag^{commit}"
