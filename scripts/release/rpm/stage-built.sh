#!/usr/bin/env bash
#
# In the job that builds one distribution and architecture, right after the build and before
# anything installs or runs what it made: require that the build left exactly the packages of that
# leg (scripts/release/rpm/names.sh), copy them to a directory of their own, which is what is
# uploaded, and print "<name>=<sha256>" for each, on one line. A file more, a file less, a link, a
# file over the size cap or a directory is a failed build.
#
# Usage: stage-built.sh <version> <id> <arch> <built-dir> <stage-dir>
#   <stage-dir> must be empty or absent.
# Exit 0 when the set is exact and staged, 1 when it is not, 2 for a usage error.

set -euo pipefail

[ "$#" -eq 5 ] || { echo "usage: stage-built.sh <version> <id> <arch> <built-dir> <stage-dir>" >&2; exit 2; }
version="$1" id="$2" arch="$3" built="$4" stage="$5"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The cap the rpm channel puts on a package.
max_rpm=$((300 * 1024 * 1024))

names="$(bash "$here/names.sh" leg "$version" "$id" "$arch")" || { echo "the packages of $id $arch cannot be named" >&2; exit 1; }
[ -d "$built" ] && [ ! -L "$built" ] || { echo "$built is not a directory" >&2; exit 1; }
want="$(awk '{print $0 " f"}' <<< "$names" | LC_ALL=C sort)"
got="$(cd "$built" && find . -mindepth 1 -printf '%P %y\n' | LC_ALL=C sort)"
[ "$got" = "$want" ] || { printf 'the build of %s %s did not leave exactly its packages.\nexpected:\n%s\nfound:\n%s\n' "$id" "$arch" "$want" "$got" >&2; exit 1; }
if [ -e "$stage" ]; then
	[ -d "$stage" ] && [ ! -L "$stage" ] && [ -z "$(ls -A "$stage")" ] || { echo "$stage is not an empty directory" >&2; exit 1; }
fi
mkdir -p "$stage"
hashes=""
while IFS= read -r name; do
	[ "$(stat -c %s -- "$built/$name")" -le "$max_rpm" ] || { echo "$name is over the size cap of $max_rpm bytes" >&2; exit 1; }
	install -m 0644 -- "$built/$name" "$stage/$name"
	sum="$(sha256sum -- "$stage/$name")"
	hashes+="$name=${sum%% *} "
done <<< "$names"
printf '%s\n' "${hashes% }"
