#!/usr/bin/env bash
#
# Tests for controls that live in workflow steps rather than in scripts, so no
# script test can see them go: the signing step refuses to publish without the
# signing key or without one package per architecture, keyring-watch refuses
# anything from upstream that is not a plain public key, and the build checks out
# the commit the plan saw. Each step's run block is read from the workflow and run
# here, under the shell GitHub uses, with fakes for what it calls.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# step, run_step and says: read a step out of a workflow and run it.
# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

# --- release.yml, publish: the step that holds the signing key -------------------
# It is found by the secret it holds, and every other secret it is given is set, so
# the case under test is the Ed25519 key alone. python3 stops the run where signing
# would begin: reaching it means both refusals let the packages through.
S="$WORK/sign"
if step release.yml publish secret=GLYNDOR_RELEASE_ED25519_KEY "$S"; then
	check "the signing step's run block has no expression in it" 0 "$(grep -c '\${{' "$S/run.sh")"
	mkdir -p "$S/bin"
	printf '#!/bin/sh\necho "signing would start: $*"\nexit 42\n' > "$S/bin/python3"
	chmod +x "$S/bin/python3"
	others=()
	while IFS= read -r v; do
		[ "$v" = GLYNDOR_RELEASE_ED25519_KEY ] || others+=("$v=set-by-the-test")
	done < "$S/secrets"
	sign() { # <number of packages> <key>
		rm -rf "$S/art"; mkdir "$S/art"
		local i
		for ((i = 1; i <= $1; i++)); do : > "$S/art/podman_6.2.0_arch$i.deb"; done
		run_step "$S" "$S/art" PATH="$S/bin:$PATH" RUNNER_TEMP="$S/rt" GITHUB_WORKSPACE="$HERE" \
			"${others[@]}" GLYNDOR_RELEASE_ED25519_KEY="$2"
	}
	sign 2 ""
	check "no signing key: refused before signing" "1 0" "$rc $(says 'signing would start')"
	check "and it says the key is not configured" 1 "$(says 'GLYNDOR_RELEASE_ED25519_KEY is not configured')"
	for n in 1 3; do
		sign "$n" a-key
		check "$n packages: refused before signing" "1 0" "$rc $(says 'signing would start')"
		check "and it says one package per architecture is expected" 1 "$(says 'expected one package per architecture')"
	done
	sign 2 a-key
	check "a key and two packages: signing starts" "42 1" "$rc $(says 'signing would start')"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that holds the signing key"
fi

# --- keyring-watch.yml: what comes from upstream must be a plain public key -------
K="$WORK/keys"
if step keyring-watch.yml compare "name=Refuse anything that is not a plain public key" "$K"; then
	check "the key check's run block has no expression in it" 0 "$(grep -c '\${{' "$K/run.sh")"
	block='-----BEGIN PGP PUBLIC KEY BLOCK-----'
	upstream() { # <name> <how>: an upstream with one good key and one file made <how>
		rm -rf "$K/rt"; mkdir -p "$K/rt/release-keys/podman" "$K/elsewhere"
		local d="$K/rt/release-keys/podman"
		printf '%s\n\nmDMEZ\n-----END PGP PUBLIC KEY BLOCK-----\n' "$block" > "$d/good.asc"
		case "$2" in
			good) cp "$d/good.asc" "$d/$1" ;;
			symlink) cp "$d/good.asc" "$K/elsewhere/target.asc"; ln -s "$K/elsewhere/target.asc" "$d/$1" ;;
			large) { printf '%s\n' "$block"; head -c 200001 /dev/zero | tr '\0' 'A'; } > "$d/$1" ;;
			not-a-block) printf 'hello\n' > "$d/$1" ;;
			private) printf '%s\nPRIVATE\n' "$block" > "$d/$1" ;;
		esac
		run_step "$K" "$K" RUNNER_TEMP="$K/rt"
	}
	upstream second.asc good
	check "two plain public keys pass" 0 "$rc"
	upstream link.asc symlink
	check "a symlink to a valid key is refused" "1 1" "$rc $(says 'link.asc is not a plain file')"
	upstream key.txt good
	check "a valid key in a file that is not .asc is refused" "1 1" "$rc $(says 'key.txt is not a .asc file')"
	upstream big.asc large
	check "a key block larger than a key should be is refused" "1 1" "$rc $(says 'big.asc is larger than a key should be')"
	upstream plain.asc not-a-block
	check "a file that is not a public key block is refused" "1 1" "$rc $(says 'plain.asc is not a public key block')"
	upstream secret.asc private
	check "a public key block that mentions PRIVATE is refused" "1 1" "$rc $(says 'secret.asc mentions a private key')"
	rm -rf "$K/rt"; mkdir -p "$K/rt/release-keys"
	run_step "$K" "$K" RUNNER_TEMP="$K/rt"
	check "an upstream with no podman/ directory is refused" "1 1" "$rc $(says 'upstream has no podman/ directory')"
else
	fail=$((fail + 1)); echo "FAIL  keyring-watch.yml: cannot find the key check"
fi

# --- reusable-build.yml: build exactly the commit the plan saw --------------------
# git clone makes the directory, rev-parse HEAD answers $HEAD_AT, and verify-tag.sh
# (the step runs it from the checkout) answers $SIGNED_AT, the commit the tag signs.
B="$WORK/build"
if step reusable-build.yml build "name=Fetch the upstream tags and verify their signatures" "$B"; then
	check "the fetch step's run block has no expression in it" 0 "$(grep -c '\${{' "$B/run.sh")"
	mkdir -p "$B/bin" "$B/ws/scripts/upstream"
	cat > "$B/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$1" in
	clone) mkdir -p "${!#}" ;;
	-C) [ "$3 $4" = "rev-parse HEAD" ] && echo "$HEAD_AT" ;;
esac
GIT
	printf '#!/bin/sh\necho "$SIGNED_AT"\n' > "$B/ws/scripts/upstream/verify-tag.sh"
	chmod +x "$B/bin/git"
	fetch() { # <head> <signed> <plan for podman> <plan for netavark> <plan for aardvark-dns>
		rm -rf "$B/rt"; mkdir "$B/rt"
		run_step "$B" "$B/ws" PATH="$B/bin:$PATH" RUNNER_TEMP="$B/rt" HEAD_AT="$1" SIGNED_AT="$2" \
			PODMAN=v6.2.0 NETAVARK=v2.1.0 AARDVARK=v2.1.3 PODMAN_SHA="$3" NETAVARK_SHA="$4" AARDVARK_SHA="$5"
	}
	fetch c1 c1 c1 c1 c1
	check "the commit the plan saw is built" "0 3" "$rc $(says 'verified')"
	fetch c1 c1 c1 c2 c1
	check "a tag that moved since the plan is refused" "1 1" "$rc $(says 'netavark v2.1.0 is at c1, the plan saw c2')"
	check "and nothing after it is fetched" 0 "$(says 'verified aardvark-dns')"
	fetch c9 c1 c1 c1 c1
	check "a checkout that is not the signed commit is refused" "1 0" "$rc $(says 'verified')"
else
	fail=$((fail + 1)); echo "FAIL  reusable-build.yml: cannot find the fetch step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
