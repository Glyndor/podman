# shellcheck shell=bash
# A copy of what scripts/upstream/read-released.sh needs from the repository, with keys made for the run, and the signing
# of a record under them, for the suites that feed it a release.
signing_repo() { # <source repository> <destination> <directory for the keys>
	mkdir -p "$2/scripts/upstream" "$2/.github/scripts/release" "$2/keyring"
	cp "$1/scripts/upstream/read-released.sh" "$2/scripts/upstream/"
	cp "$1/.github/scripts/release/sign.py" "$1/.github/scripts/release/verify-sig.py" "$1/.github/scripts/release/sign-requirements.txt" "$2/.github/scripts/release/"
	python3 -I "$1/.github/scripts/release/dry-run-keys.py" "$3" > /dev/null
	cp "$3/ed25519.b64" "$2/keyring/glyndor-release-ed25519.b64"
	printf '# no second key yet\n' > "$2/keyring/glyndor-release-mldsa65.b64"
}
sign_record() { # <source repository> <directory of the keys> <record>: writes <record>.sig
	( read -r GLYNDOR_RELEASE_ED25519_KEY < "$2/ed25519.seed" && export GLYNDOR_RELEASE_ED25519_KEY \
		&& python3 -I "$1/.github/scripts/release/sign.py" "$3" > /dev/null )
}
