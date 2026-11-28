#!/usr/bin/env bash
#
# Tests for the steps of the job that signs in .github/workflows/release.yml, run under the shell the workflow gives
# them with fakes for python: the second (ML-DSA-65) signature, required once its public key is committed and verified
# against it, the throwaway keys of a rehearsal, and the step that installs the signing library.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"
# shellcheck source=tests/lib/release-workflow.sh
. "$HERE/tests/lib/release-workflow.sh"
# shellcheck source=tests/lib/rpm-set.sh
. "$HERE/tests/lib/rpm-set.sh"
small_table "$WORK/distros.txt"

# --- release.yml, sign: the step that signs, and the second signature --------------
S="$WORK/sign"
if step release.yml sign secret=GLYNDOR_RELEASE_ED25519_KEY "$S"; then
	check "the signing step's run block has no expression in it" 0 "$(grep -c '\${{' "$S/run.sh")"
	mkdir -p "$S/bin"
	cat > "$S/venv-python" <<'PY'
#!/bin/sh
echo "$*" >> "$CALLS"
# What the step signs with, written down for the cases that look at it.
case "$*" in
	*sign.py*) echo "ed=$GLYNDOR_RELEASE_ED25519_KEY mldsa=$GLYNDOR_RELEASE_MLDSA65_KEY" >> "$CALLS.keys" ;;
	*dry-run-keys.py*)
		# The throwaway keys: a directory with a seed and a public anchor of each.
		dir="$3"; mkdir "$dir"
		echo dry-ed-seed > "$dir/ed25519.seed"; echo "# throwaway" > "$dir/ed25519.b64"
		case "$*" in *--mldsa*) echo dry-mldsa-seed > "$dir/mldsa65.seed"; echo "# throwaway" > "$dir/mldsa65.b64" ;; esac ;;
esac
exit 0
PY
	chmod +x "$S/venv-python"
	WS="$S/ws"
	EXTRA_ENV=()
	ANCHOR="$WS/keyring/glyndor-release-mldsa65.b64"
	REL="$WS/.github/scripts/release"
	# The third argument is what the plan said about the newest release, false by default.
	sign() { # <anchor: empty|keyed|missing|indented|committed|cr|crlf|bom|tab|nul|high> <mldsa secret, may be empty> [previous]
		rm -rf "$S/art" "$S/rt" "$WS" "$S/calls" "$S/calls.keys" "$S/out"; mkdir -p "$S/art" "$S/rt/signvenv/bin" "$WS/keyring"
		: > "$S/calls"; : > "$S/out"
		# The environment the step before made, and the packages the check of the download let through.
		cp "$S/venv-python" "$S/rt/signvenv/bin/python"
		sign_stage "$WS" "$S/rt/stage" 6.2.0
		local gone
		for gone in "${EXTRA_ENV[@]}"; do case "$gone" in MISSING=*) rm "$S/rt/stage/${gone#MISSING=}" ;; esac; done
		# The switch as committed, which requires nothing: release-second-signature.test.sh
		# runs this step with it on.
		cp "$HERE/keyring/second-signature-required" "$WS/keyring/"
		# The Ed25519 anchor as committed, unless $ED names a broken one.
		case "${ED:-committed}" in
			committed) cp "$HERE/keyring/glyndor-release-ed25519.b64" "$WS/keyring/" ;;
			missing) ;;
			*) printf '%b' "$ED" > "$WS/keyring/glyndor-release-ed25519.b64" ;;
		esac
		case "$1" in
			empty) printf '# Glyndor release ML-DSA-65 public keys.\n# Empty until the key exists.\n' > "$ANCHOR" ;;
			indented) printf '# Glyndor release ML-DSA-65 public keys.\n\n   # an indented comment\n  \n' > "$ANCHOR" ;;
			keyed) printf '# Glyndor release ML-DSA-65 public keys.\nAAAAAAAAAAAAAAAA\n' > "$ANCHOR" ;;
			missing) ;;
			committed) cp "$HERE/keyring/glyndor-release-mldsa65.b64" "$ANCHOR" ;;
			# What the verifier reads as a comment line and then a key line.
			cr) printf '# Glyndor release ML-DSA-65 public keys.\rAAAAAAAAAAAAAAAA\r' > "$ANCHOR" ;;
			crlf) printf '# Glyndor release ML-DSA-65 public keys.\r\nAAAAAAAAAAAAAAAA\r\n' > "$ANCHOR" ;;
			bom) printf '\357\273\277# Glyndor release ML-DSA-65 public keys.\n' > "$ANCHOR" ;;
			tab) printf '# Glyndor release ML-DSA-65 public keys.\n\t# a comment behind a tab\n' > "$ANCHOR" ;;
			# A NUL makes GNU grep read the file as binary, where its pattern matches
			# nothing, so a guard that matched lines let this one through.
			nul) printf '# Glyndor release ML-DSA-65 public keys.\000# behind a NUL\n' > "$ANCHOR" ;;
			high) printf '# Glyndor release ML-DSA-65 public keys.\n# \200 a byte past ASCII\n' > "$ANCHOR" ;;
		esac
		run_step "$S" "$S/art" PATH="$S/bin:$PATH" RUNNER_TEMP="$S/rt" GITHUB_WORKSPACE="$WS" \
			GITHUB_OUTPUT="$S/out" CALLS="$S/calls" TAG=v6.2.0 PODMAN=v6.2.0 NETAVARK=v2.1.0 AARDVARK=v2.1.3 RECIPE=r1 \
			GLYNDOR_RELEASE_ED25519_KEY=an-ed25519-seed GLYNDOR_RELEASE_MLDSA65_KEY="$2" PREVIOUS_MLDSA="${3-false}" "${EXTRA_ENV[@]}"
	}
	verify_line() { # <deb> [--require-mldsa]: the call the step must make for a package
		printf -- '-I %s/verify-sig.py %s %s.sig %s/keyring/glyndor-release-ed25519.b64 --mldsa-sig %s.mldsa65.sig --mldsa-keys %s%s' \
			"$REL" "$1" "$1" "$WS" "$1" "$ANCHOR" "${2:+ $2}"
	}
	calls() { grep -c -x -F -- "$1" "$S/calls"; }
	signed() { grep -c 'sign.py ' "$S/calls"; }

	# --- a rehearsal: throwaway keys, the real path, and the secrets not read ---------
	# The real secrets are in the environment of these runs on purpose: a rehearsal has to sign with its own.
	EXTRA_ENV=(DRY_RUN=true)
	sign empty ""
	check "a rehearsal with no key in the anchor goes through, with the Ed25519 key only" "0 1" "$rc $(grep -c -x -e '-I '"$REL"'/dry-run-keys.py '"$S"'/rt/dry' "$S/calls")"
	check "and it signs with the throwaway key, not the secret" "ed=dry-ed-seed mldsa=" "$(sort -u "$S/calls.keys")"
	check "and each package is verified against the throwaway anchor" "1 1" \
		"$(calls "-I $REL/verify-sig.py $S/rt/stage/podman_6.2.0_amd64.deb $S/rt/stage/podman_6.2.0_amd64.deb.sig $S/rt/dry/ed25519.b64 --mldsa-sig $S/rt/stage/podman_6.2.0_amd64.deb.mldsa65.sig --mldsa-keys $ANCHOR") $(calls "-I $REL/verify-sig.py $S/rt/stage/podman_6.2.0_arm64.deb $S/rt/stage/podman_6.2.0_arm64.deb.sig $S/rt/dry/ed25519.b64 --mldsa-sig $S/rt/stage/podman_6.2.0_arm64.deb.mldsa65.sig --mldsa-keys $ANCHOR")"
	check "and the public half is kept for the check that follows" "ed25519.b64" "$(ls "$S/rt/dry-public" | paste -sd' ')"
	sign keyed AAAA-a-seed
	check "a rehearsal when the real anchor holds a key makes a second throwaway key" "0 1 ed=dry-ed-seed mldsa=dry-mldsa-seed" \
		"$rc $(grep -c -e '--mldsa$' "$S/calls") $(sort -u "$S/calls.keys")"
	check "and requires the second signature, as the real configuration does" "1 1" \
		"$(calls "$(printf -- '-I %s/verify-sig.py %s %s.sig %s/rt/dry/ed25519.b64 --mldsa-sig %s.mldsa65.sig --mldsa-keys %s/rt/dry/mldsa65.b64 --require-mldsa' "$REL" "$S/rt/stage/podman_6.2.0_amd64.deb" "$S/rt/stage/podman_6.2.0_amd64.deb" "$S" "$S/rt/stage/podman_6.2.0_amd64.deb" "$S")") $(grep -c -x require_mldsa=true "$S/out")"
	check "and its public halves are both kept" "ed25519.b64 mldsa65.b64" "$(ls "$S/rt/dry-public" | paste -sd' ')"
	EXTRA_ENV=(DRY_RUN=true GLYNDOR_RELEASE_ED25519_KEY=)
	sign empty ""
	check "a rehearsal does not need the signing secret, which it is not given" "0" "$rc"
	EXTRA_ENV=(GLYNDOR_RELEASE_ED25519_KEY=)
	sign empty ""
	check "a release with no signing secret is still refused" "1 1" "$rc $(says 'GLYNDOR_RELEASE_ED25519_KEY is not configured')"
	EXTRA_ENV=()

	for state in empty indented; do
		sign "$state" ""
		check "$state anchor, no secret: the packages go through" "0 true" "$rc $(grep -qx require_mldsa=false "$S/out" && echo true)"
		check "$state anchor, no secret: each package is verified against the anchor, with no requirement" \
			"1 1" "$(calls "$(verify_line "$S/rt/stage/podman_6.2.0_amd64.deb")") $(calls "$(verify_line "$S/rt/stage/podman_6.2.0_arm64.deb")")"
		check "$state anchor, no secret: every package, the record and the list of hashes are signed first" "18" "$(signed)"
		check "$state anchor, no secret: every one of them, by name" "$(signed_names 6.2.0 | sed "s#^#$S/rt/stage/#")" \
			"$(sed -n 's#^-I [^ ]*/sign\.py ##p' "$S/calls")"
		check "$state anchor, no secret: the record is verified too" "1" "$(calls "$(verify_line "$S/rt/stage/components.txt")")"
		check "$state anchor, no secret: the record is the one of this release and these components" "release v6.2.0|podman v6.2.0|netavark v2.1.0|aardvark-dns v2.1.3|recipe r1|ids $(bash "$HERE/scripts/package/distros.sh" ids rpm | paste -sd' ')|recipe-package $(bash "$HERE/scripts/build/recipe-id.sh" "$HERE/scripts/package")" "$(paste -sd'|' "$S/rt/stage/components.txt")"
		check "$state anchor, no secret: the list of hashes names every package and the record" "17 0" \
			"$(grep -c . "$S/rt/stage/SHA256SUMS") $(cd "$S/rt/stage" && sha256sum --strict -c SHA256SUMS > /dev/null 2>&1; echo "$?")"
	done
	sign keyed AAAA-a-seed
	check "a committed key and the secret: the packages go through" "0" "$rc"
	# Nothing is installed or built while a key is in the environment: the library was put in
	# place by a step before this one, from an empty directory and with no secret.
	check "and nothing is installed or built while the keys are in the environment" 0 "$(grep -c -e pip -e venv "$S/calls")"
	check "and every call starts the interpreter isolated" 0 "$(grep -c -v -e '^-I ' "$S/calls")"
	check "and each package is verified against the anchor with the second signature required" \
		"1 1" "$(calls "$(verify_line "$S/rt/stage/podman_6.2.0_amd64.deb" --require-mldsa)") $(calls "$(verify_line "$S/rt/stage/podman_6.2.0_arm64.deb" --require-mldsa)")"
	check "and the release is told it is required" 1 "$(grep -c -x require_mldsa=true "$S/out")"
	check "and nothing is verified that was not signed first" "18 sign 18 verify" \
		"$(sed -n 's#^-I [^ ]*/\(sign\|verify-sig\)\.py .*#\1#p' "$S/calls" | sed 's/-sig//' | uniq -c | awk '{print $1, $2}' | paste -sd' ')"
	missing=podmansh-6.2.0+r1-1.glyndor.el9.noarch.rpm
	EXTRA_ENV=(MISSING="$missing")
	sign keyed AAAA-a-seed
	check "a package that is not there when the list of hashes is written: stopped before anything is signed" "1 1 0" \
		"$rc $(says 'SHA256SUMS is not written without every file') $(signed)"
	EXTRA_ENV=()
	sign keyed ""
	check "a committed key and no secret: refused" "1" "$rc"
	check "and it says the secret is what is missing" 1 "$(says 'holds a public key and GLYNDOR_RELEASE_MLDSA65_KEY is not configured')"
	check "and nothing is signed" 0 "$(signed)"
	sign empty a-seed
	check "a secret and no committed key: the second signature is still required of the verifier" \
		"0 1 1" "$rc $(calls "$(verify_line "$S/rt/stage/podman_6.2.0_amd64.deb" --require-mldsa)") $(calls "$(verify_line "$S/rt/stage/podman_6.2.0_arm64.deb" --require-mldsa)")"
	sign committed ""
	check "the anchor this repository commits, no secret: the packages go through" "0 18" "$rc $(signed)"
	# A carriage return is a line break to the verifier and not to this step, so a
	# key behind one would be a comment here and required of nobody.
	for state in cr crlf bom tab nul high; do
		sign "$state" ""
		check "an anchor with a byte outside printable ASCII and the line feed ($state), no secret: refused" "1" "$rc"
		check "$state: and it says which file and why" 1 "$(says 'holds a byte that is neither printable ASCII nor a line feed')"
		check "$state: and nothing is signed" 0 "$(signed)"
	done
	# The Ed25519 anchor is read by verify-sig.py, which splits on every line break
	# Python knows, and by docs/verify.md and the apt archive, which split on the line
	# feed. Behind a carriage return, a U+0085 or a NUL, a key is a comment to one and
	# a key to the other, so the same guard holds it, and the file as committed passes.
	key="$(grep -v '^#' "$HERE/keyring/glyndor-release-ed25519.b64" | head -n 1)"
	check "the Ed25519 anchor as committed holds one key and passes the guard" "1 0" \
		"$(grep -c -v '^#' "$HERE/keyring/glyndor-release-ed25519.b64") $(LC_ALL=C tr -d ' -~\n' < "$HERE/keyring/glyndor-release-ed25519.b64" | wc -c)"
	ed_bytes='keyring/glyndor-release-ed25519.b64 holds a byte that is neither printable ASCII nor a line feed'
	for state in "cr:# Glyndor release keys\r$key\n" "crlf:$key\r\n" "bom:\357\273\277$key\n" "tab:\t$key\n" \
		"nul:# a comment\0000$key\n" "high:# \200\n$key\n" "nel:\302\205$key\n$key\n"; do
		ED="${state#*:}" sign committed ""
		check "an Ed25519 anchor with a byte outside printable ASCII and the line feed (${state%%:*}): refused" "1 1" "$rc $(says "$ed_bytes")"
		check "${state%%:*}: and nothing is signed" 0 "$(signed)"
	done
	ED=missing sign committed ""
	check "no Ed25519 anchor at all: refused before anything is signed" "1 1 0" \
		"$rc $(says 'keyring/glyndor-release-ed25519.b64 is missing; refusing to publish') $(signed)"
	# --- once a release carries the second signature, the next one cannot drop it ---
	downgrade='the newest release carries an ML-DSA-65 signature and keyring/glyndor-release-mldsa65.b64 holds no key'
	for secret in "" a-seed; do
		sign empty "$secret" true
		check "the newest release signed twice, an emptied anchor, secret '${secret:-unset}': refused" "1" "$rc"
		check "and it says the anchor lost the key the last release was verified with" 1 "$(says "$downgrade")"
		check "and nothing is signed" 0 "$(signed)"
	done
	sign committed "" true
	check "the anchor as committed today, after a release signed twice: refused for the downgrade" "1 1" "$rc $(says "$downgrade")"
	sign keyed a-seed true
	check "the newest release signed twice, a key and the secret: the packages go through, both required" "0 1 1" \
		"$rc $(calls "$(verify_line "$S/rt/stage/podman_6.2.0_amd64.deb" --require-mldsa)") $(grep -c -x require_mldsa=true "$S/out")"
	sign keyed "" true
	check "the newest release signed twice, a key and no secret: refused for the secret" "1 1 0" \
		"$rc $(says 'GLYNDOR_RELEASE_MLDSA65_KEY is not configured') $(says "$downgrade")"
	for previous in "" yes; do
		sign empty "" "$previous"
		check "a plan that says '${previous:-nothing}' about the newest release: refused, not read as no" "1 1 0" \
			"$rc $(says 'the plan did not say whether the newest release carries the second signature') $(signed)"
	done
	sign missing ""
	check "no anchor file at all: refused, not read as no key" "1" "$rc"
	check "and it says the anchor is missing" 1 "$(says 'is missing; refusing to publish')"
	check "and nothing is signed" 0 "$(signed)"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that holds the signing key"
fi

# --- release.yml, sign: the step that installs the signing library -------------------
# It holds no secret, starts from an empty directory of its own and installs by hash.
I="$WORK/install"
if step release.yml sign "name=Install the signing library" "$I"; then
	check "the install step's run block has no expression in it" 0 "$(grep -c '\${{' "$I/run.sh")"
	check "and it holds no secret" 0 "$(wc -l < "$I/secrets" | tr -d ' ')"
	mkdir -p "$I/bin" "$I/ws/.github/scripts/release"
	cat > "$I/bin/python3" <<'PY'
#!/bin/sh
echo "cwd=$(pwd) python3 $*" >> "$CALLS"
[ "$1 $2" = "-I -m" ] && [ "$3" = venv ] || exit 99
mkdir -p "$4/bin"
printf '#!/bin/sh\necho "cwd=$(pwd) venv-python $*" >> "$CALLS"\n' > "$4/bin/python"
chmod +x "$4/bin/python"
PY
	chmod +x "$I/bin/python3"
	: > "$I/calls"; rm -rf "$I/rt"; mkdir "$I/rt"
	run_step "$I" "$I/ws" PATH="$I/bin:$PATH" RUNNER_TEMP="$I/rt" GITHUB_WORKSPACE="$I/ws" CALLS="$I/calls"
	check "the library is installed by hash, binary only, from the file of the checkout, with the isolated interpreter" \
		"cwd=$I/rt/tools venv-python -I -m pip install --quiet --require-hashes --only-binary=:all: -r $I/ws/.github/scripts/release/sign-requirements.txt" \
		"$(tail -n 1 "$I/calls")"
	check "and the environment is made isolated, from the same empty directory" "cwd=$I/rt/tools python3 -I -m venv $I/rt/signvenv" "$(head -n 1 "$I/calls")"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that installs the signing library"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
