#!/usr/bin/env bash
#
# Tests for what scripts/upstream/verify-tag.sh does with tags that are signed, and well, but not the way the keys it
# pins say: with an X.509 certificate, with an SSH key, with an OpenPGP key that is valid and is not in the keys
# directory, through a configuration that names another program, and with an exit status of git that is not 0. All of
# them are real repositories and real keys in temporary directories. A tag signed by a subkey of a pinned key has to
# pass, since the primary key is what the status names last.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/verify-tag.sh"
WORK="$(mktemp -d)"
# The agents that gpg and gpgsm start keep the output of the suite open until they are told to stop.
cleanup() { for h in "$WORK"/gh-*; do GNUPGHOME="$h" gpgconf --kill all > /dev/null 2>&1; done; rm -rf "$WORK"; }
trap cleanup EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G=(git -c user.name=t -c user.email=t@x)
mkdir -m 700 "$WORK/gh-pinned" "$WORK/gh-stranger" "$WORK/keys"

# A pinned key with a signing subkey of its own, and a key that is valid and is not pinned.
GNUPGHOME="$WORK/gh-pinned" gpg --batch --quiet --passphrase '' --quick-generate-key "pinned <pinned@x>" ed25519 cert never 2> /dev/null
primary="$(GNUPGHOME="$WORK/gh-pinned" gpg --batch --with-colons --list-keys pinned@x 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')"
GNUPGHOME="$WORK/gh-pinned" gpg --batch --quiet --passphrase '' --quick-add-key "$primary" ed25519 sign never 2> /dev/null
subkey="$(GNUPGHOME="$WORK/gh-pinned" gpg --batch --with-colons --list-keys --with-subkey-fingerprint pinned@x 2> /dev/null | awk -F: '/^fpr/ {n++; if (n == 2) print $10}')"
GNUPGHOME="$WORK/gh-pinned" gpg --batch --armor --export pinned@x > "$WORK/keys/pinned.asc" 2> /dev/null
GNUPGHOME="$WORK/gh-stranger" gpg --batch --quiet --passphrase '' --quick-generate-key "stranger <stranger@x>" ed25519 sign never 2> /dev/null
stranger="$(GNUPGHOME="$WORK/gh-stranger" gpg --batch --with-colons --list-keys stranger@x 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')"

repo="$WORK/repo"
git init -q "$repo"
"${G[@]}" -C "$repo" commit -q --allow-empty -m c
commit="$(git -C "$repo" rev-parse HEAD)"
pgp_tag() { # <tag> <gnupghome> <key> [message]
	GNUPGHOME="$2" "${G[@]}" -C "$repo" -c gpg.format=openpgp -c gpg.program=gpg -c "user.signingkey=$3" tag -s -m "${4:-$1}" "$1" > /dev/null 2>&1
}
pgp_tag v1 "$WORK/gh-pinned" "$subkey!"
pgp_tag v2 "$WORK/gh-stranger" "$stranger"
"${G[@]}" -C "$repo" -c tag.gpgSign=false tag -a -m unsigned v3
# An SSH signature.
ssh-keygen -q -t ed25519 -N '' -f "$WORK/ssh" > /dev/null
"${G[@]}" -C "$repo" -c gpg.format=ssh -c "user.signingkey=$WORK/ssh.pub" tag -s -m ssh v4 > /dev/null 2>&1
# An X.509 one, from a self-signed certificate that its own keyring trusts: git would check it with gpgsm.
mkdir -m 700 "$WORK/gh-x509"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/x.pem" -out "$WORK/x.crt" -subj "/CN=attacker" -days 2 2> /dev/null
openssl pkcs12 -export -inkey "$WORK/x.pem" -in "$WORK/x.crt" -out "$WORK/x.p12" -passout pass: 2> /dev/null
printf 'allow-loopback-pinentry\n' > "$WORK/gh-x509/gpg-agent.conf"; printf 'disable-crl-checks\n' > "$WORK/gh-x509/gpgsm.conf"
timeout 20 env GNUPGHOME="$WORK/gh-x509" gpgsm --batch --pinentry-mode loopback --passphrase '' --import "$WORK/x.p12" > /dev/null 2>&1
xfpr="$(timeout 20 env GNUPGHOME="$WORK/gh-x509" gpgsm --batch --list-keys --with-colons 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')"
printf '%s S\n' "$xfpr" > "$WORK/gh-x509/trustlist.txt"
timeout 20 env GNUPGHOME="$WORK/gh-x509" git -c user.name=t -c user.email=t@x -C "$repo" -c gpg.format=x509 -c gpg.x509.program=gpgsm -c "user.signingkey=$xfpr" tag -s -m x509 v5 > /dev/null 2>&1
# The same tag made by hand, for the machine where gpgsm cannot sign: the kind is told by the header of the signature,
# whether or not what follows is a good one.
printf 'object %s\ntype commit\ntag v5s\ntagger t <t@x> 1795000000 +0000\n\nx509 by hand\n-----BEGIN SIGNED MESSAGE-----\nMIIB\n-----END SIGNED MESSAGE-----\n' "$commit" \
	| git -C "$repo" hash-object -t tag -w --stdin | xargs -I{} git -C "$repo" update-ref refs/tags/v5s {}
# An OpenPGP signature behind a line that starts another kind of signature: git decides from the first such line.
pgp_tag v6 "$WORK/gh-pinned" "$subkey!" "$(printf 'look\n-----BEGIN SSH SIGNATURE-----\nnothing\n')"

# A tag changed after it was signed (BADSIG), and a tag whose signature expired (EXPSIG): the second needs a key that
# existed in 2019, a signature made in 2020 that was good for a day, and a gpg that is told so through its own options.
mkdir -m 700 "$WORK/gh-dated"
printf 'faked-system-time 20190101T000000\n' > "$WORK/gh-dated/gpg.conf"
GNUPGHOME="$WORK/gh-dated" gpg --batch --quiet --passphrase '' --quick-generate-key "dated <dated@x>" ed25519 sign never 2> /dev/null
dated="$(GNUPGHOME="$WORK/gh-dated" gpg --batch --with-colons --list-keys dated@x 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')"
GNUPGHOME="$WORK/gh-dated" gpg --batch --armor --export dated@x > "$WORK/keys-dated.asc" 2> /dev/null
printf 'faked-system-time 20200101T000000\ndefault-sig-expire 1d\n' > "$WORK/gh-dated/gpg.conf"
pgp_tag v7 "$WORK/gh-dated" "$dated"
# The signature of v1 on an object that says it is v8: the name is part of what was signed.
tampered="$(git -C "$repo" cat-file tag v1 | sed '0,/^tag v1$/s//tag v8/' | git -C "$repo" hash-object -t tag -w --stdin)"
git -C "$repo" update-ref refs/tags/v8 "$tampered"
mkdir "$WORK/keys-dated"; cp "$WORK/keys-dated.asc" "$WORK/keys-dated/dated.asc"; cp "$WORK/keys/pinned.asc" "$WORK/keys-dated/"
run() { "$SCRIPT" "$repo" "$1" "$WORK/keys" > "$WORK/out" 2> "$WORK/err"; rc=$?; out="$(cat "$WORK/out")"; }
refused() { # <desc> <tag> <reason> [VAR=value]...
	local desc="$1" tag="$2" reason="$3"; shift 3
	err="$(env "$@" "$SCRIPT" "$repo" "$tag" "$WORK/keys" 2>&1 > /dev/null)"; local rc=$?
	check "$desc is refused" 1 "$rc"
	check "$desc: the reason is '$reason'" 1 "$(printf '%s\n' "$err" | grep -c -F -- "$reason")"
}

run v1
check "a tag signed by a subkey of a pinned key passes: the primary key is what the status names last" "0 $commit" "$rc $out"
refused "a tag signed with a valid OpenPGP key that is not pinned" v2 "rejected: ERRSIG"
refused "a tag with no signature" v3 "has no good signature"
refused "a tag signed with an SSH key" v4 "is not signed with OpenPGP: it starts its signature with '-----BEGIN SSH SIGNATURE-----'"
if git -C "$repo" cat-file tag v5 | grep -q '^-----BEGIN SIGNED MESSAGE-----$'; then
	refused "a tag signed with an X.509 certificate" v5 "is not signed with OpenPGP: it starts its signature with '-----BEGIN SIGNED MESSAGE-----'"
else
	echo "note  gpgsm could not sign a tag here: the X.509 tag made by hand is the one tried"
fi
refused "a tag whose signature is an X.509 one made by hand" v5s "is not signed with OpenPGP: it starts its signature with '-----BEGIN SIGNED MESSAGE-----'"
refused "a tag whose message holds the line of another kind of signature before an OpenPGP one" v6 "is not signed with OpenPGP"

refused "a tag changed after it was signed" v8 "rejected: BADSIG"
dated_dir="$WORK/keys-dated"
err="$("$SCRIPT" "$repo" v7 "$dated_dir" 2>&1 > /dev/null)"; rc=$?
check "a tag whose signature expired is refused" 1 "$rc"
check "a tag whose signature expired: the reason is 'rejected: EXPSIG'" 1 "$(printf '%s\n' "$err" | grep -c -F -- 'rejected: EXPSIG')"
# The configuration of the user, the system or the repository names a program that says what it is asked to say.
cat > "$WORK/liar" <<LIAR
#!/bin/sh
echo "[GNUPG:] NEWSIG" >&2
echo "[GNUPG:] GOODSIG 1111111111111111 liar" >&2
echo "[GNUPG:] VALIDSIG $primary 2026-11-23 1 0 4 0 22 10 00 $primary" >&2
exit 0
LIAR
chmod +x "$WORK/liar"
printf '[gpg]\n\tprogram = %s\n[gpg "openpgp"]\n\tprogram = %s\n[gpg]\n\tminTrustLevel = never\n' "$WORK/liar" "$WORK/liar" > "$WORK/evil.config"
refused "a tag of a key that is not pinned, with a global configuration that names a program that says it is good" v2 "rejected: ERRSIG" "GIT_CONFIG_GLOBAL=$WORK/evil.config"
refused "a tag of a key that is not pinned, with the configuration given through the environment" v2 "rejected: ERRSIG" \
	"GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=gpg.openpgp.program" "GIT_CONFIG_VALUE_0=$WORK/liar"
git -C "$repo" config gpg.openpgp.program "$WORK/liar"; git -C "$repo" config gpg.format ssh
refused "a tag of a key that is not pinned, with a repository whose configuration names the liar and another format" v2 "rejected: ERRSIG"
run v1; check "and a pinned one still passes in that repository" "0 $commit" "$rc $out"
git -C "$repo" config --unset gpg.openpgp.program; git -C "$repo" config --unset gpg.format

# The exit status of git is read: a status that says good and an exit that does not are refused.
mkdir "$WORK/shim"
printf '#!/bin/sh\nreal=%s\n"$real" "$@"\nrc=$?\ncase " $* " in *" verify-tag "*) exit 1 ;; esac\nexit $rc\n' "$(command -v git)" > "$WORK/shim/git"; chmod +x "$WORK/shim/git"
refused "a tag whose status is good and whose git exits 1" v1 "rejected: git verify-tag exited 1" "PATH=$WORK/shim:$PATH"
printf '#!/bin/sh\nreal=%s\ncase " $* " in *" verify-tag "*) echo "fatal: could not run" >&2; exit 128 ;; esac\nexec "$real" "$@"\n' "$(command -v git)" > "$WORK/shim/git"
refused "a git that says nothing of a signature" v1 "git could not check the signature (exit 128)" "PATH=$WORK/shim:$PATH"

# The fingerprints the verdict is tied to.
GNUPGHOME="$WORK/gh-pinned" bash -c '. "$1"; gpg_primary_fingerprints' _ "$HERE/scripts/upstream/gpg-verdict.sh" > "$WORK/fprs"
check "the primary fingerprints of a keyring are its primary keys', not its subkeys'" "$primary" "$(cat "$WORK/fprs")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
