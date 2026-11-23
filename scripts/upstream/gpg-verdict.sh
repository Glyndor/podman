# shellcheck shell=bash
#
# What the status lines of gpg say about a signature, in one place, for the two gates that decide whether
# something somebody else signed is trusted: verify-tag.sh for the upstream tags and fetch-extras.sh for the
# release tarballs of the programs packaged beside Podman. Sourced, never run.
#
#   gpg_has_status <status>          0 when there is at least one status line, whatever it says. A gpg that could
#                                    not run, or a verifier that failed before it spoke, has none.
#   gpg_primary_fingerprints         the fingerprints of the primary keys in the keyring of GNUPGHOME, one per line:
#                                    what a gate that imported its pinned keys is pinned to.
#   gpg_verdict <status> <fingerprint>...
#                                    0 for a good signature, and nothing is printed. Otherwise 1, and the reason is
#                                    printed: the name of the status that refused it, "no good signature", or "not
#                                    made by a pinned key (<the fingerprint it names>)". Without a fingerprint it is a
#                                    mistake of the caller, 2 and a message on stderr, and never "anyone will do".
#
# What is refused, and why each is needed. VALIDSIG alone is not a verdict: gpg also reports it for a key that has
# expired or been revoked and for a signature that has expired. For one signature gpg reports exactly one of
# GOODSIG, BADSIG, EXPSIG, EXPKEYSIG, REVKEYSIG or ERRSIG, so requiring GOODSIG refuses the expired and the revoked,
# and a list of the others refuses what comes with a good one: a file or a tag can carry more than one signature, and
# a good one beside an unknown key's (ERRSIG, NO_PUBKEY) must not pass. KEYREVOKED is listed as well, since a
# revoked key says it on a line of its own. And a good signature is not enough either: the keyring that checked it
# holds the keys the gate imported, but a signature can be good and made by a key that is in no way the one pinned
# (a keyring of the user, a program that was not asked for). So the last field of EVERY VALIDSIG line, which is the
# fingerprint of the primary key whatever subkey signed, has to be one of the fingerprints given.

gpg_has_status() {
	grep -q '^\[GNUPG:\] ' <<< "$1"
}

gpg_primary_fingerprints() {
	gpg --batch --with-colons --list-keys 2> /dev/null \
		| awk -F: '$1 == "pub" {want = 1; next} $1 == "sub" {want = 0; next} $1 == "fpr" && want {print $10; want = 0}'
}

gpg_verdict() {
	local status="$1" bad pinned fingerprint last
	shift
	if [ "$#" -eq 0 ]; then
		echo "gpg_verdict needs the fingerprints of the keys it trusts" >&2
		return 2
	fi
	for fingerprint in "$@"; do
		[[ "$fingerprint" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] || { echo "gpg_verdict: '$fingerprint' is not a fingerprint" >&2; return 2; }
		pinned+=" ${fingerprint^^} "
	done
	for bad in BADSIG EXPSIG EXPKEYSIG REVKEYSIG KEYREVOKED ERRSIG NO_PUBKEY; do
		if grep -q -E "^\[GNUPG:\] $bad( |\$)" <<< "$status"; then
			printf '%s\n' "$bad"
			return 1
		fi
	done
	if ! grep -q '^\[GNUPG:\] GOODSIG ' <<< "$status" || ! grep -q '^\[GNUPG:\] VALIDSIG ' <<< "$status"; then
		printf '%s\n' "no good signature"
		return 1
	fi
	while read -r last; do
		case "$pinned" in
			*" ${last^^} "*) ;;
			*) printf 'not made by a pinned key (%s)\n' "$last"; return 1 ;;
		esac
	done < <(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {print $NF}' <<< "$status")
	return 0
}
