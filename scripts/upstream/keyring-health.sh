#!/usr/bin/env bash
#
# Say whether enough of the trusted keys will still be able to sign. Prints each
# key with the day it expires, and exits 1 when fewer than <minimum> of them are
# still valid <days> days from <now>.
#
# A release is signed by one maintainer. If the keys that remain valid are one, a
# single departure or expiry stops every release, and nothing says so until the
# tag that cannot be verified. Keys already expired when this repository got them
# are listed but do not count.
#
# Usage: keyring-health.sh <keys-dir> <now-epoch> <days> <minimum>

set -euo pipefail

keys="${1:?keys directory}"; now="${2:?now}"; days="${3:?days}"; minimum="${4:?minimum}"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

shopt -s nullglob
files=("$keys"/*.asc)
[ ${#files[@]} -gt 0 ] || { echo "no keys under $keys" >&2; exit 2; }
gpg --batch --quiet --import "${files[@]}" \
	|| { echo "could not import the keys under $keys" >&2; exit 2; }

horizon=$((now + days * 86400))
valid=0
# Field 2 of a pub record is what gpg itself concluded about the key today: e is
# expired, r is revoked, d is disabled. A revoked key has no expiry date to read,
# so the dates alone would count it as good.
while IFS=: read -r kind validity _ _ keyid created expires _; do
	[ "$kind" = pub ] || continue
	ok=1
	case "$validity" in e | r | d | i) ok=0; why="$validity" ;; esac
	if [ -z "$expires" ]; then when="never"
	else
		when="$(date -u -d "@$expires" +%F)"
		[ "$expires" -gt "$horizon" ] || { ok=0; why="${why:-expires inside the window}"; }
	fi
	uid="$(gpg --batch --with-colons --list-keys "$keyid" 2>/dev/null | awk -F: '/^uid/ {print $10; exit}' | sed 's/ <.*//')"
	case "${why:-}" in
		e) note=" - expired" ;; r) note=" - revoked" ;; d) note=" - disabled" ;; i) note=" - invalid" ;;
		"") note="" ;; *) note=" - not valid in the window" ;;
	esac
	echo "$keyid ($uid) expires $when$note"
	valid=$((valid + ok))
	why=""
	: "$created"
done < <(gpg --batch --with-colons --list-keys 2>/dev/null)

echo "$valid key(s) still valid $days days from now, $minimum needed"
[ "$valid" -ge "$minimum" ]
