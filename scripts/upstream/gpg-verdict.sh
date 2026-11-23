# shellcheck shell=bash
#
# What the status lines of gpg say about a signature, in one place, for the two gates that decide whether
# something somebody else signed is trusted: verify-tag.sh for the upstream tags and fetch-extras.sh for the
# release tarballs of the programs packaged beside Podman. Sourced, never run.
#
#   gpg_has_status <status>          0 when there is at least one status line, whatever it says. A gpg that could
#                                    not run, or a verifier that failed before it spoke, has none.
#   gpg_verdict <status> [fingerprint]
#                                    0 for a good signature, and nothing is printed. Otherwise 1, and the reason is
#                                    printed: the name of the status that refused it, "no good signature", or
#                                    "not made by <fingerprint>".
#
# What is refused, and why each is needed. VALIDSIG alone is not a verdict: gpg also reports it for a key that has
# expired or been revoked and for a signature that has expired. For one signature gpg reports exactly one of
# GOODSIG, BADSIG, EXPSIG, EXPKEYSIG, REVKEYSIG or ERRSIG, so requiring GOODSIG refuses the expired and the revoked,
# and a list of the others refuses what comes with a good one: a file or a tag can carry more than one signature, and
# a good one beside an unknown key's (ERRSIG, NO_PUBKEY) must not pass. KEYREVOKED is listed as well, since a
# revoked key says it on a line of its own. With a fingerprint, the VALIDSIG line has to end in it: its last field is
# the fingerprint of the primary key, which is what a pinned key file names.

gpg_has_status() {
	grep -q '^\[GNUPG:\] ' <<< "$1"
}

gpg_verdict() {
	local status="$1" fingerprint="${2:-}" bad
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
	if [ -n "$fingerprint" ] && ! grep -q -E "^\[GNUPG:\] VALIDSIG .* $fingerprint\$" <<< "$status"; then
		printf '%s\n' "not made by $fingerprint"
		return 1
	fi
	return 0
}
