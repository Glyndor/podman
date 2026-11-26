#!/usr/bin/env bash
#
# Write the components.txt of the newest published release to <out>. The plan
# compares it with what upstream has now, and a difference means "build".
#
# The record is read only once it is shown to be the one the release signed: components.txt.sig, and the
# second signature when keyring/glyndor-release-mldsa65.b64 holds a key, verify against the keys of this
# checkout, and its line `release <tag>` names the release it was downloaded from. A pre-release is not a
# release a host installed and is not looked at. The one exception is the release that was published before
# records were signed, named in keyring/release-without-signed-components as its tag and the sha256 of its
# record: only that pair is accepted without a signature, and the line goes once a release with a signed
# record exists. Anything else that cannot be shown to be signed is an error, so the run fails in red and
# neither a plan nor a healthy verdict comes out of it. RELEASE_VERIFY_PYTHON names an interpreter that has
# the signing library; without it one is made here from the pinned requirements.
#
# An empty file means this repository has no release yet. A release that exists
# but whose components cannot be read is an error, never an empty file: read as
# "nothing released" it makes every scheduled run build and publish another +rN,
# with nobody asking. That is what happened once: the file was created empty
# first and `gh release download` refuses to overwrite it, and the failure was
# swallowed.
#
# It prints the tag of that release, or nothing when there is none, so the second
# form can ask about the same release without looking it up again.
#
# The second form writes the names of the assets of release <tag> to <assets>, one per
# line, so the release can tell whether the newest one carries a second signature. It
# is asked only when a run is going to build, and the tag is the one the first form
# printed, so neither the release list nor components.txt is fetched twice. An empty
# <tag> is no release yet, and an empty file. A listing that cannot be read, or that
# does not even name components.txt, is an error: read as "no assets" it would say the
# newest release carried no second signature, which is the answer that lets the next
# one leave without it.
#
# Needs gh and, as for gh itself, GH_TOKEN and GH_REPO (or a repository checkout).
#
# Usage: read-released.sh <out>
#        read-released.sh --assets <tag> <assets>

set -euo pipefail

if [ "${1:-}" = --assets ]; then
	[ "$#" -eq 3 ] || { echo "usage: read-released.sh --assets <tag> <assets>" >&2; exit 2; }
	tag="$2"
	assets="$3"
	rm -f "$assets"
	if [ -z "$tag" ]; then
		: > "$assets"
		exit 0
	fi
	gh release view "$tag" --json assets --jq '.assets[].name' > "$assets" \
		|| { echo "cannot list the assets of release $tag" >&2; exit 1; }
	grep -qx 'components.txt' "$assets" \
		|| { echo "the asset list of release $tag does not name components.txt" >&2; exit 1; }
	exit 0
fi

out="${1:?out file}"
[ "$#" -eq 1 ] || { echo "usage: read-released.sh <out>" >&2; exit 2; }

latest="$(gh release list --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName // empty')"
rm -f "$out"
if [ -z "$latest" ]; then
	: > "$out"
	exit 0
fi

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
record="$work/components.txt"
fetch() { # <asset> <to>
	# Whatever gh prints goes to stderr: stdout carries the tag and nothing else.
	gh release download "$latest" --pattern "$1" --output "$2" --clobber >&2
}
fetch components.txt "$record" || { echo "release $latest has no readable components.txt" >&2; exit 1; }
grep -q '^podman ' "$record" \
	|| { echo "components.txt of $latest names no podman version" >&2; exit 1; }

if ! fetch components.txt.sig "$record.sig"; then
	pin="$here/keyring/release-without-signed-components"
	sum="$(sha256sum "$record" | cut -d' ' -f1)"
	grep -qxF "$latest $sum" "$pin" 2> /dev/null \
		|| { echo "release $latest carries no readable signature of its components.txt, and it is not the release named in ${pin#"$here"/} with that record" >&2; exit 1; }
else
	py="${RELEASE_VERIFY_PYTHON:-}"
	if [ -z "$py" ]; then
		py="$work/venv/bin/python"
		if ! python3 -I -m venv "$work/venv" >&2 \
			|| ! "$py" -I -m pip install --quiet --require-hashes --only-binary=:all: -r "$here/.github/scripts/release/sign-requirements.txt" >&2; then
			echo "the signing library could not be installed to verify components.txt" >&2
			exit 1
		fi
	fi
	anchor="$here/keyring/glyndor-release-mldsa65.b64"
	args=("$record" "$record.sig" "$here/keyring/glyndor-release-ed25519.b64")
	# A second signature is required whenever the anchor holds a key for it, so that dropping the file from a
	# release cannot make a record pass with one signature.
	if grep -qvE '^[[:space:]]*(#|$)' "$anchor" 2> /dev/null; then
		fetch components.txt.mldsa65.sig "$record.mldsa65.sig" || { echo "release $latest has no readable components.txt.mldsa65.sig" >&2; exit 1; }
		args+=(--mldsa-sig "$record.mldsa65.sig" --mldsa-keys "$anchor" --require-mldsa)
	fi
	"$py" -I "$here/.github/scripts/release/verify-sig.py" "${args[@]}" >&2 \
		|| { echo "the signature of components.txt of $latest does not verify" >&2; exit 1; }
	if [ "$(grep -c '^release ' "$record")" != 1 ] || ! grep -qxF "release $latest" "$record"; then
		echo "components.txt of $latest does not name that release, once" >&2
		exit 1
	fi
fi
cp "$record" "$out"
printf '%s\n' "$latest"
