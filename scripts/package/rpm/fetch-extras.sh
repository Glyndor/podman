#!/usr/bin/env bash
#
# Fetch and verify the sources of the dependencies a distribution takes beside podman, on the
# runner, before any of them is compiled: a tarball whose signature is made by the pinned key, or
# a tag that resolves to the pinned commit (scripts/package/extras.txt says which each one is).
# Anything that does not verify stops the job, and nothing is compiled from it.
#
# Each source ends in <dest>/<name>/ : a tarball as src.tar.<ext>, a clone as a tree without .git.
#
# Usage: fetch-extras.sh <id> <dest>
# GLYNDOR_EXTRAS_FILE and GLYNDOR_KEYS_DIR move the table and the keys, for tests.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="${1:?distribution id}"
dest="$(mkdir -p "${2:?destination}" && cd "$2" && pwd)"
table="${GLYNDOR_EXTRAS_FILE:-$here/../extras.txt}"
keys="${GLYNDOR_KEYS_DIR:-$here/../../../keyring/extras}"
# The verdict on a signature is the one the gate of the upstream tags gives (see gpg-verdict.sh).
# shellcheck source=scripts/upstream/gpg-verdict.sh
. "$here/../../upstream/gpg-verdict.sh"

# What an upstream may make the runner download and keep before anything of it is trusted: a source that was not forged
# can still be made enormous, and the signature or the pin is only checked after the bytes are on the disk. A tarball and
# its signature are cut at their cap and a clone is cut at its cap, and every transfer has a time limit; going over any of
# them is a refusal that says which. The caps are far above the real sources (crun 1.8 MB, passt and conmon a few MB) and
# the variables move them, for the tests. The transfers are https only (GLYNDOR_EXTRAS_PROTOCOLS moves that for the tests too).
max_tarball="${GLYNDOR_EXTRAS_MAX_TARBALL:-33554432}"
max_signature="${GLYNDOR_EXTRAS_MAX_SIGNATURE:-65536}"
max_git="${GLYNDOR_EXTRAS_MAX_GIT:-134217728}"
max_seconds="${GLYNDOR_EXTRAS_MAX_SECONDS:-300}"
protocols="${GLYNDOR_EXTRAS_PROTOCOLS:-https}"

# fetch_capped <url> <file> <cap in bytes> <what>: the file, or an exit that says why not. The stream is cut one byte past
# the cap, so a server that sends more than it announced, or does not announce, is stopped as well as one that announces.
fetch_capped() {
	local rc=0 size
	# --max-time bounds one attempt and --retry makes up to four, so the whole is bounded by timeout as well, and
	# --retry-max-time keeps curl from starting an attempt it could not finish inside it.
	timeout "$max_seconds" curl -fsSL --retry 3 --retry-max-time "$max_seconds" --max-time "$max_seconds" --max-filesize "$3" \
		--proto "=$protocols" --proto-redir "=$protocols" "$1" | head -c "$(($3 + 1))" > "$2" || rc=$?
	size="$(stat -c %s "$2" 2> /dev/null || echo 0)"
	# curl stops by itself at the cap with an error, having written exactly the cap; the cut of head is for the stream that
	# curl does not stop. Either way the file is over the cap.
	if [ "$size" -gt "$3" ] || { [ "$rc" -ne 0 ] && [ "$size" -ge "$3" ]; }; then
		rm -f "$2"
		echo "$4 is larger than the $3 bytes allowed: $1" >&2
		exit 1
	fi
	# 124 is timeout giving up, 28 is curl giving up on an attempt at the same moment.
	if [ "$rc" -eq 124 ] || [ "$rc" -eq 28 ]; then
		rm -f "$2"
		echo "$4 took more than the $max_seconds seconds allowed: $1" >&2
		exit 1
	fi
	[ "$rc" -eq 0 ] && [ "$size" -gt 0 ] || { rm -f "$2"; echo "cannot fetch $4: $1" >&2; exit 1; }
}

wanted="$(bash "$here/../distros.sh" field "$id" extras)"
gnupg="$(mktemp -d)"
# The agent of the temporary keyring is closed before its folder goes, and the folder of sockets it made under /run goes
# with it: none is left running, and nothing of it is left on the disk.
cleanup() {
	gpgconf --homedir "$gnupg" --kill all > /dev/null 2>&1 || true
	gpgconf --homedir "$gnupg" --remove-socketdir > /dev/null 2>&1 || true
	rm -rf "$gnupg"
}
trap cleanup EXIT
export GNUPGHOME="$gnupg"

for name in ${wanted//,/ }; do
	row="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$table" | awk -F'|' -v n="$name" '$1 == n' || true)"
	[ -n "$row" ] || { echo "$name is not in $table" >&2; exit 1; }
	IFS='|' read -r _ version _ kind source pin keyfile fingerprint <<< "$row"
	out="$dest/$name"
	rm -rf "$out"
	mkdir -p "$out"
	case "$kind" in
		tarball)
			case "$source" in *.tar.gz) ext=tar.gz ;; *.tar.xz) ext=tar.xz ;; *) echo "$name: $source is not a tarball" >&2; exit 1 ;; esac
			fetch_capped "$source" "$out/src.$ext" "$max_tarball" "the tarball of $name"
			fetch_capped "$source.asc" "$out/src.$ext.asc" "$max_signature" "the signature of $name"
			[ "$(sha256sum "$out/src.$ext" | cut -d' ' -f1)" = "${pin#sha256:}" ] \
				|| { echo "$name: the tarball is not the one pinned in extras.txt" >&2; exit 1; }
			gpg --batch --quiet --import "$keys/$keyfile" || { echo "cannot import $keyfile" >&2; exit 1; }
			# A gpg that could not run says nothing in its status, and a bad signature says what is wrong with it: both
			# refuse, each with its own reason. The exit status of gpg is read, not swallowed.
			rc=0
			status="$(gpg --batch --status-fd 1 --verify "$out/src.$ext.asc" "$out/src.$ext" 2> "$gnupg/gpg.err")" || rc=$?
			if ! gpg_has_status "$status"; then
				echo "$name: gpg could not check the signature (exit $rc): $(tr '\n' ' ' < "$gnupg/gpg.err")" >&2
				exit 1
			fi
			# Every VALIDSIG of the status has to name the pinned primary key, and gpg has to exit 0 as well.
			vrc=0
			reason="$(gpg_verdict "$status" "$fingerprint")" || vrc=$?
			[ "$vrc" -eq 0 ] \
				|| { echo "$name: the signature is rejected: ${reason:-extras.txt names no usable fingerprint} (the key pinned is $fingerprint)" >&2; exit 1; }
			[ "$rc" -eq 0 ] || { echo "$name: gpg found the signature good and exited $rc, which is refused" >&2; exit 1; }
			echo "verified $name $version: tarball signed by $fingerprint" ;;
		git)
			tag="${pin%%=*}"
			commit="${pin#*=}"
			# Only the tag asked for, by its full ref and one commit deep, is fetched: a clone of everything is as big as the
			# upstream makes it before the pin is looked at, a branch called like the tag is not even asked for, and what is
			# extracted is the commit the tag was pinned to, read back from the tree itself. The fetch is cut at a size, by
			# the limit on the size of a file that it writes (the pack is one), and at a time.
			git init --quiet "$out/tree"
			git -C "$out/tree" remote add origin "$source"
			fetch_rc=0
			(
				ulimit -f "$((max_git / 1024))"
				# unpackLimit=1 keeps what arrives as ONE pack file however few objects it holds: below the default of 100 objects
				# git unpacks them as loose files, each under the limit on a file, and the whole is over the cap before the
				# size on the disk is read.
				GIT_ALLOW_PROTOCOL="$protocols" timeout "$max_seconds" git -C "$out/tree" -c fetch.unpackLimit=1 -c transfer.unpackLimit=1 \
					fetch --quiet --depth 1 --no-tags origin "+refs/tags/$tag:refs/tags/$tag"
			) 2> "$gnupg/git.err" || fetch_rc=$?
			if [ "$fetch_rc" -ne 0 ]; then
				echo "cannot fetch $tag of $source within $max_git bytes and $max_seconds seconds (exit $fetch_rc): $(tr '\n' ' ' < "$gnupg/git.err")" >&2
				exit 1
			fi
			# A second line, after the fetch: what is on the disk is not over the cap either.
			[ "$(du -sb "$out/tree/.git" | cut -f1)" -le "$max_git" ] \
				|| { echo "$name: $tag of $source is larger than the $max_git bytes allowed" >&2; exit 1; }
			[ "$(git -C "$out/tree" rev-parse "refs/tags/$tag^{commit}")" = "$commit" ] \
				|| { echo "$name: the tag $tag is not at the commit pinned in extras.txt" >&2; exit 1; }
			# Plain commands: a failure of either stops the script (set -e) before the tree is used.
			git -C "$out/tree" checkout --quiet --detach "$commit"
			test "$(git -C "$out/tree" rev-parse HEAD)" = "$commit"
			rm -rf "$out/tree/.git"
			echo "verified $name $version: $tag is $commit (the project signs neither; the commit is pinned)" ;;
		*) echo "$name: unknown kind $kind" >&2; exit 1 ;;
	esac
done
