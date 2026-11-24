#!/usr/bin/env bash
#
# Tests for scripts/package/rpm/fetch-extras.sh with throwaway keys and local sources: a tarball is
# accepted when it is the one pinned and its signature is a good one made by the pinned
# fingerprint, a tag is accepted when it is at the pinned commit, and everything else stops the
# job before anything is compiled.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/rpm/fetch-extras.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

export GNUPGHOME="$WORK/gpg"; mkdir -m 700 "$GNUPGHOME"
mkkey() { # <name>: a key with no passphrase, its public half in keys/<name>-<fingerprint>.asc; prints the fingerprint
	gpg --batch --quiet --passphrase '' --quick-generate-key "$1 <$1@example.org>" ed25519 sign never 2> /dev/null
	local fp
	fp="$(gpg --batch --list-keys --with-colons "$1@example.org" | awk -F: '/^fpr/ {print $10; exit}')"
	mkdir -p "$WORK/keys"
	gpg --batch --armor --export "$fp" > "$WORK/keys/$1-$fp.asc"
	echo "$fp"
}
good="$(mkkey good)"; other="$(mkkey other)"

# the sources: a tarball signed by the good key, and a repository with a tag
mkdir -p "$WORK/srv/tool-1.0"; echo 'int main(void){return 0;}' > "$WORK/srv/tool-1.0/main.c"
tar -C "$WORK/srv" -czf "$WORK/srv/tool.tar.gz" tool-1.0
gpg --batch --armor --detach-sign --local-user "$good" -o "$WORK/srv/tool.tar.gz.asc" "$WORK/srv/tool.tar.gz" 2> /dev/null
gpg --batch --armor --detach-sign --local-user "$other" -o "$WORK/srv/tool.other.asc" "$WORK/srv/tool.tar.gz" 2> /dev/null
sum="sha256:$(sha256sum "$WORK/srv/tool.tar.gz" | cut -d' ' -f1)"
git init -q "$WORK/srv/repo"; git -C "$WORK/srv/repo" -c user.email=a@b -c user.name=a commit -q --allow-empty -m one
git -C "$WORK/srv/repo" -c user.email=a@b -c user.name=a tag -a v1 -m v1
commit="$(git -C "$WORK/srv/repo" rev-parse 'v1^{commit}')"

# curl: the url is a file name under srv, and a name that is not there fails like a 404
mkdir "$WORK/bin"
cat > "$WORK/bin/curl" <<'CURL'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -*) ;; *) url="$1" ;; esac; shift; done
src="$SRV/${url##*/}"
[ -n "${SWAP_SIG:-}" ] && case "$url" in *.asc) src="$SRV/$SWAP_SIG" ;; esac
[ -f "$src" ] && cp "$src" "$out"
CURL
chmod +x "$WORK/bin/curl"
export SRV="$WORK/srv"
PATH="$WORK/bin:$PATH"

# a table with a signed tarball, a pinned tag and a distribution that takes both
table() { # <sha pin> <fingerprint> <tag commit> [key file, the good key's by default]
	printf 'tool|1.0|0|tarball|https://x.example/tool.tar.gz|%s|%s|%s\nrepo|1|0|git|%s|v1=%s|-|-\n' \
		"$1" "${4:-good-$good.asc}" "$2" "$WORK/srv/repo" "$3" > "$WORK/extras.txt"
}
printf 'fx|rpm|fedora|x86_64|5|2|5|upstream|0^20260716||crun\n' > "$WORK/distros.txt"
# the real row names crun and passt; the test uses its own names through its own tables
export GLYNDOR_DISTROS_FILE="$WORK/distros.txt" GLYNDOR_EXTRAS_FILE="$WORK/extras.txt" GLYNDOR_KEYS_DIR="$WORK/keys"
fetch() { rm -rf "$WORK/dest"; out="$("$SCRIPT" fx "$WORK/dest" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
use() { printf 'fx|rpm|fedora|x86_64|5|2|5|upstream|0^20260716||%s\n' "$1" > "$WORK/distros.txt"; }

# The extras column of a real table only names the four; run the script over a copy of itself that
# accepts these two names, so the table check of distros.sh is not what is under test here.
cp "$HERE/scripts/package/distros.sh" "$WORK/distros.sh"
sed -i 's/(crun|conmon|catatonit|passt)/(crun|conmon|catatonit|passt|tool|repo)/g' "$WORK/distros.sh"
mkdir -p "$WORK/s/package/rpm" "$WORK/s/upstream"; cp "$WORK/distros.sh" "$WORK/s/package/distros.sh"; cp "$SCRIPT" "$WORK/s/package/rpm/fetch-extras.sh"
cp "$HERE/scripts/upstream/gpg-verdict.sh" "$WORK/s/upstream/gpg-verdict.sh"
SCRIPT="$WORK/s/package/rpm/fetch-extras.sh"

use tool; table "$sum" "$good" "$commit"
fetch
check "a signed tarball that is the one pinned is accepted" 0 "$rc"
check "and it is kept as a tarball beside its signature" "src.tar.gz src.tar.gz.asc" "$(ls "$WORK/dest/tool" | paste -sd' ')"
check "and said to be verified, with the fingerprint" 1 "$(says "verified tool 1.0: tarball signed by $good")"
table "sha256:0000000000000000000000000000000000000000000000000000000000000000" "$good" "$commit"; fetch
check "a tarball that is not the pinned one is refused" "1 1" "$rc $(says 'is not the one pinned in extras.txt')"
table "$sum" "$other" "$commit"; fetch
check "a good signature made by another fingerprint is refused, and the reason is the key" "1 1" "$rc $(says "the signature is rejected: not made by a pinned key")"
SWAP_SIG=tool.other.asc table "$sum" "$good" "$commit"; SWAP_SIG=tool.other.asc fetch
check "a signature of another key over the pinned tarball is refused, as a key gpg does not know" "1 1" "$rc $(says 'the signature is rejected: ERRSIG')"
mv "$WORK/srv/tool.tar.gz" "$WORK/srv/tool.tar.gz.off"; table "$sum" "$good" "$commit"; fetch
check "a tarball that cannot be fetched is refused" "1 1" "$rc $(says 'cannot fetch https://x.example/tool.tar.gz')"
mv "$WORK/srv/tool.tar.gz.off" "$WORK/srv/tool.tar.gz"
mv "$WORK/srv/tool.tar.gz.asc" "$WORK/srv/tool.tar.gz.asc.off"; table "$sum" "$good" "$commit"; fetch
check "a tarball with no signature to fetch is refused" "1 1" "$rc $(says 'cannot fetch the signature')"
mv "$WORK/srv/tool.tar.gz.asc.off" "$WORK/srv/tool.tar.gz.asc"
echo tampered >> "$WORK/srv/tool.tar.gz"; table "sha256:$(sha256sum "$WORK/srv/tool.tar.gz" | cut -d' ' -f1)" "$good" "$commit"; fetch
check "a tarball changed after it was signed is refused even when the pin follows it, as a bad signature" "1 1" "$rc $(says 'the signature is rejected: BADSIG')"
# The keys gpg still prints VALIDSIG for: one that expired after it signed, and one that was revoked after it signed.
# Each tarball here is signed while its key is good, the pin follows the file, and the key file is the one that is
# committed: the verdict is gpg's, over keys made here, in a keyring of their own.
sum2="sha256:$(sha256sum "$WORK/srv/tool.tar.gz" | cut -d' ' -f1)"
GNUPGHOME="$WORK/gpg-old" ; mkdir -m 700 "$GNUPGHOME"; export GNUPGHOME
gpg --batch --quiet --passphrase '' --faked-system-time 20200101T000000 --quick-generate-key "old <old@example.org>" ed25519 sign 1d 2> /dev/null
old="$(gpg --batch --list-keys --with-colons old@example.org 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')"
gpg --batch --armor --export "$old" > "$WORK/keys/old-$old.asc"
gpg --batch --quiet --armor --detach-sign --faked-system-time 20200101T010000 --local-user "$old" -o "$WORK/srv/tool.old.asc" "$WORK/srv/tool.tar.gz" 2> /dev/null
SWAP_SIG=tool.old.asc table "$sum2" "$old" "$commit" "old-$old.asc"; SWAP_SIG=tool.old.asc fetch
check "a signature of a key that has expired is refused, though gpg prints a VALIDSIG for it" "1 1" "$rc $(says 'the signature is rejected: EXPKEYSIG')"
export GNUPGHOME="$WORK/gpg-rev"; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-generate-key "rev <rev@example.org>" ed25519 cert never 2> /dev/null
rev="$(gpg --batch --list-keys --with-colons rev@example.org 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')"
gpg --batch --quiet --passphrase '' --quick-add-key "$rev" ed25519 sign never 2> /dev/null
sub="$(gpg --batch --list-keys --with-colons --with-subkey-fingerprint rev@example.org 2> /dev/null | awk -F: '/^fpr/ {n++; if (n == 2) print $10}')"
gpg --batch --quiet --armor --detach-sign --local-user "$sub!" -o "$WORK/srv/tool.rev.asc" "$WORK/srv/tool.tar.gz" 2> /dev/null
gpg --batch --armor --export "$rev" > "$WORK/keys/rev-$rev.asc"
SWAP_SIG=tool.rev.asc table "$sum2" "$rev" "$commit" "rev-$rev.asc"; SWAP_SIG=tool.rev.asc fetch
check "before the revocation the same signature is accepted" 0 "$rc"
gpg --batch --command-fd 0 --edit-key "$rev" > /dev/null 2>&1 <<< $'key 1\nrevkey\ny\n0\n\ny\nsave\n'
gpg --batch --armor --export "$rev" > "$WORK/keys/rev-$rev.asc"
SWAP_SIG=tool.rev.asc table "$sum2" "$rev" "$commit" "rev-$rev.asc"; SWAP_SIG=tool.rev.asc fetch
check "a signature of a key that was revoked is refused, though gpg prints a VALIDSIG for it" "1 1" "$rc $(says 'the signature is rejected: REVKEYSIG')"
export GNUPGHOME="$WORK/gpg"
# A gpg whose status is good and whose exit is not 0 is refused, and so is a table with no usable fingerprint.
mkdir -p "$WORK/liargpg"
printf '#!/bin/sh\ncase " $* " in *" --verify "*) echo "[GNUPG:] GOODSIG 1111111111111111 x" ; echo "[GNUPG:] VALIDSIG %s 2026-11-23 1 0 4 0 22 10 00 %s"; exit 1 ;; esac\nexec %s "$@"\n' "$good" "$good" "$(command -v gpg)" > "$WORK/liargpg/gpg"; chmod +x "$WORK/liargpg/gpg"
table "$sum2" "$good" "$commit"; PATH="$WORK/liargpg:$PATH" fetch
check "a good status with an exit that is not 0 is refused" "1 1" "$rc $(says 'gpg found the signature good and exited 1')"
table "$sum2" "not-a-fingerprint" "$commit"; fetch
check "a table with no usable fingerprint is refused, and says so" "1 1" "$rc $(says 'extras.txt names no usable fingerprint')"
# A gpg that cannot check anything says nothing in its status, which is not the same refusal as a bad signature.
mkdir "$WORK/nogpg"
printf '#!/bin/sh\ncase " $* " in *" --verify "*) echo "gpg: cannot open the keyring" >&2; exit 2 ;; esac\nexec %s "$@"\n' "$(command -v gpg)" > "$WORK/nogpg/gpg"; chmod +x "$WORK/nogpg/gpg"
table "$sum2" "$good" "$commit"; PATH="$WORK/nogpg:$PATH" fetch
check "a gpg that could not run is refused with a reason of its own, not as a bad signature" "1 1 0" "$rc $(says 'gpg could not check the signature (exit 2)') $(says 'the signature is rejected')"
mv "$WORK/keys/good-$good.asc" "$WORK/keys/good-$good.asc.off"; fetch
check "a key file that is not there is refused, and it says which" "1 1" "$rc $(says 'cannot import good-')"
mv "$WORK/keys/good-$good.asc.off" "$WORK/keys/good-$good.asc"

use repo; table "$sum" "$good" "$commit"; fetch
check "a tag at the pinned commit is accepted" 0 "$rc"
check "and the tree is kept without its history" "0" "$([ -d "$WORK/dest/repo/tree/.git" ] && echo 1 || echo 0)"
check "and it is said that nothing signs it" 1 "$(says 'the project signs neither')"
table "$sum" "$good" "0000000000000000000000000000000000000000"; fetch
check "a tag that is not at the pinned commit is refused" "1 1" "$rc $(says 'is not at the commit pinned')"
# A branch called like the tag, at another commit: --branch would have taken the branch.
git -C "$WORK/srv/repo" -c user.email=a@b -c user.name=a checkout -q -b v1
git -C "$WORK/srv/repo" -c user.email=a@b -c user.name=a commit -q --allow-empty -m branch-only
git -C "$WORK/srv/repo" checkout -q -
table "$sum" "$good" "$commit"; use repo; fetch
check "a remote with a branch called like the tag, at another commit, is refused" "1 1" "$rc $(says 'has a branch called v1')"
git -C "$WORK/srv/repo" branch -q -D v1
fetch
check "and the tag alone is accepted again" 0 "$rc"
check "and the tree extracted is the pinned commit" "1" "$([ -d "$WORK/dest/repo/tree" ] && echo 1 || echo 0)"
printf 'repo|1|0|git|%s/absent|v1=%s|-|-\n' "$WORK/srv" "$commit" > "$WORK/extras.txt"; fetch
check "a repository that cannot be cloned is refused" "1 1" "$rc $(says 'cannot clone')"
printf 'repo|1|0|svn|x|v1=%s|-|-\n' "$commit" > "$WORK/extras.txt"; fetch
check "a kind nobody knows is refused" "1 1" "$rc $(says 'unknown kind svn')"
printf 'tool|1.0|0|tarball|https://x.example/tool.zip|%s|good-%s.asc|%s\n' "$sum" "$good" "$good" > "$WORK/extras.txt"; use tool; fetch
check "a source that is not a tarball is refused" "1 1" "$rc $(says 'is not a tarball')"
table "$sum" "$good" "$commit"; use repo; : > "$WORK/extras.txt"; fetch
check "an extra the table does not have is refused" "1 1" "$rc $(says 'is not in')"
use ""; fetch
check "a distribution that takes none fetches nothing" "0 0" "$rc $(ls "$WORK/dest" 2> /dev/null | wc -l)"
"$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
