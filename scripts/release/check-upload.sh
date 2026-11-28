#!/usr/bin/env bash
#
# Require that an artifact of this run is the one a build job reported, before anything downloads it.
#
# A build job reports the id and the digest of the artifact it uploaded, where its packages were made
# and before anything ran them. Nothing is looked up by name: a name can be taken by any step that ran
# after the build. <list> holds the artifacts of this run, one "<name> <id> <expired> <commit>
# <digest>" per line, tab separated. It must show exactly one with the reported id, called <name>,
# unexpired, made for <commit>, with the reported digest. The job that signs asks it about the two .deb
# and the rpm set, and legs.sh about each distribution and architecture.
#
# Usage: check-upload.sh <name> <id> <digest> <commit> <list>
#   <digest> is a sha256, with or without the leading "sha256:".
# Exit 0 when the artifact is the one reported, 1 when it is not, 2 for a usage error.

set -euo pipefail

[ "$#" -eq 5 ] || { echo "usage: check-upload.sh <name> <id> <digest> <commit> <list>" >&2; exit 2; }
name="$1" id="$2" digest="${3#sha256:}" commit="$4" list="$5"
die() { echo "::error::$*; refusing to take it." >&2; exit 1; }

[[ "$id" =~ ^[0-9]+$ ]] || die "the build of $name reported the artifact id '$id', not a number"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "the build of $name reported the digest '$digest', not a sha256"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "'$commit' is not a full commit id"
[ -f "$list" ] || die "there is no list of the artifacts of this run"
rows="$(awk -F'\t' -v id="$id" '$2 == id' "$list")"
[ "$(grep -c . <<< "$rows")" = 1 ] || die "this run does not list exactly one artifact with the id $id that the build of $name reported"
IFS=$'\t' read -r listed _ expired head listed_digest <<< "$rows"
[ "$listed" = "$name" ] || die "the artifact $id is called $listed, not $name"
[ "$expired" = false ] || die "the artifact $name has expired"
[ "$head" = "$commit" ] || die "the artifact $name was made for $head, not for $commit"
[ "${listed_digest#sha256:}" = "$digest" ] || die "the list of this run gives $name the digest '$listed_digest', and the build reported sha256:$digest"
echo "$name is artifact $id, sha256:$digest"
