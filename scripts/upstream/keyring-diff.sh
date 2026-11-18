#!/usr/bin/env bash
#
# Compare the keys this repository trusts with the ones upstream publishes.
# Prints one line per difference ("added", "changed" or "removed" and the file)
# and exits 1 when there is any; exits 0 when the two directories hold the same
# files with the same content.
#
# Upstream decides who may sign a Podman release, in containers/release-keys.
# The copy here is what the pipeline verifies tags against, so when upstream adds
# a key, renews one, or removes a revoked one, every release is refused until the
# copy catches up. This is how that is noticed before it happens.
#
# Usage: keyring-diff.sh <ours> <upstream>

set -euo pipefail

ours="${1:?our directory}"; upstream="${2:?upstream directory}"
[ -d "$ours" ] && [ -d "$upstream" ] || { echo "both arguments must be directories" >&2; exit 2; }

changed=0
for f in "$upstream"/*.asc; do
	[ -e "$f" ] || continue
	name="$(basename "$f")"
	if [ ! -e "$ours/$name" ]; then echo "added $name"; changed=1
	elif ! cmp -s "$f" "$ours/$name"; then echo "changed $name"; changed=1; fi
done
for f in "$ours"/*.asc; do
	[ -e "$f" ] || continue
	name="$(basename "$f")"
	[ -e "$upstream/$name" ] || { echo "removed $name"; changed=1; }
done
exit "$changed"
