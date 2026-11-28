#!/usr/bin/env bash
#
# Say which artifacts the job that gathers the rpm packages has to download, and refuse unless every
# distribution and architecture reported one that this run really holds.
#
# Each build job reports, as the output <id>_<arch> of the reusable workflow, one line:
# "<artifact id> <artifact digest> <name>=<sha256> ...", written where the packages were made and
# before anything ran them. <legs-json> is the JSON object of those outputs. For every leg of
# scripts/release/rpm/names.sh, scripts/release/check-upload.sh requires the list of the artifacts of
# this run (<list>) to show the artifact reported, by its id, called <prefix>-<id>-<arch>, unexpired,
# made for <commit>, with that digest. A leg that reported nothing, an output that is no leg, or any
# of those differing refuses the run.
#
# It prints the ids, separated by commas, in the order of the legs.
#
# Usage: legs.sh <prefix: rpm|rpmcheck> <commit> <legs-json> <list>
# Exit 0 when every leg is there, 1 when one is not, 2 for a usage error.

set -euo pipefail

[ "$#" -eq 4 ] || { echo "usage: legs.sh <prefix> <commit> <legs-json> <list>" >&2; exit 2; }
prefix="$1" commit="$2" legs_json="$3" list="$4"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "::error::$*; refusing the rpm packages." >&2; exit 1; }

case "$prefix" in rpm | rpmcheck) ;; *) die "the artifacts are called rpm- or rpmcheck-, not '$prefix-'" ;; esac
legs="$(bash "$here/names.sh" legs)" || die "the legs of distros.txt cannot be read"
keys="$(jq -r 'if type == "object" then keys[] else error("not an object") end' <<< "$legs_json")" \
	|| die "what the build jobs reported is not a JSON object"
want="$(tr ' ' '_' <<< "$legs" | LC_ALL=C sort)"
got="$(LC_ALL=C sort <<< "$keys")"
[ "$got" = "$want" ] || die "the build jobs reported $(tr '\n' ' ' <<< "$got"), and the legs of distros.txt are $(tr '\n' ' ' <<< "$want")"

ids=""
while read -r id arch; do
	leg="${id}_$arch"
	name="$prefix-$id-$arch"
	report="$(jq -r --arg k "$leg" '.[$k] | if type == "string" then . else error("not a string") end' <<< "$legs_json")" \
		|| die "the leg $leg reported something that is not text"
	read -r want_id want_digest files <<< "$report" || true
	[ -n "${files:-}" ] || die "the leg $leg reported no hash of its packages"
	bash "$here/../check-upload.sh" "$name" "${want_id:-}" "${want_digest:-}" "$commit" "$list" >&2 || exit 1
	ids+="$want_id,"
done <<< "$legs"
printf '%s\n' "${ids%,}"
