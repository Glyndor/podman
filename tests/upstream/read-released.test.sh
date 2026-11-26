#!/usr/bin/env bash
#
# Tests for scripts/upstream/read-released.sh against a fake gh that behaves like
# the real one where it matters: `release download` refuses to overwrite an
# existing file unless --clobber is given, an asset that is not there fails, and a
# release list that does not ask to leave pre-releases out returns one. The script
# runs from a copy of the repository with keys made for the run, so the records are
# signed with the real sign.py and verified with the real verify-sig.py.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/read-released.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"release list")
		case " $* " in *" --exclude-pre-releases "*) printf '%s\n' "${FAKE_LATEST:-}" ;; *) printf '%s\n' "${FAKE_PRE:-${FAKE_LATEST:-}}" ;; esac ;;
	"release download")
		clobber=0; out=""; pattern=""
		while [ $# -gt 0 ]; do
			case "$1" in --clobber) clobber=1 ;; --output) out="$2"; shift ;; --pattern) pattern="$2"; shift ;; esac
			shift
		done
		if [ -e "$out" ] && [ "$clobber" = 0 ]; then echo "$out already exists (use --clobber)" >&2; exit 1; fi
		[ -f "$FAKE_DIR/$pattern" ] || { echo "no assets match $pattern" >&2; exit 1; }
		[ "${FAKE_DOWNLOAD_FAILS:-}" != "$pattern" ] || { echo "HTTP 502" >&2; exit 1; }
		cp "$FAKE_DIR/$pattern" "$out"
		# Anything a client prints on success must not reach the caller's stdout, which
		# carries the tag and nothing else.
		echo "downloaded $pattern" ;;
	"release view")
		[ "${FAKE_VIEW_FAILS:-0}" = 0 ] || { echo "HTTP 502" >&2; exit 1; }
		[ "$3" = "${FAKE_LATEST:-}" ] || { echo "asked about $3" >&2; exit 1; }
		if [ -n "${FAKE_ASSETS+x}" ]; then printf '%b' "$FAKE_ASSETS"; else (cd "$FAKE_DIR" && ls); fi ;;
esac
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
# gh prints the tag name through --jq; the fake prints it directly.

# A copy of the repository with keys of its own, so that what is verified is signed here.
root="$WORK/repo"
mkdir -p "$root/scripts/upstream" "$root/.github/scripts/release" "$root/keyring"
cp "$HERE/scripts/upstream/read-released.sh" "$root/scripts/upstream/"
cp "$HERE/.github/scripts/release/sign.py" "$HERE/.github/scripts/release/verify-sig.py" "$HERE/.github/scripts/release/sign-requirements.txt" "$root/.github/scripts/release/"
python3 -I "$HERE/.github/scripts/release/dry-run-keys.py" "$WORK/keys" > /dev/null
python3 -I "$HERE/.github/scripts/release/dry-run-keys.py" "$WORK/other" > /dev/null
cp "$WORK/keys/ed25519.b64" "$root/keyring/glyndor-release-ed25519.b64"
printf '# no second key yet\n' > "$root/keyring/glyndor-release-mldsa65.b64"
SCRIPT="$root/scripts/upstream/read-released.sh"
export RELEASE_VERIFY_PYTHON; RELEASE_VERIFY_PYTHON="$(command -v python3)"
export FAKE_DIR="$WORK/assetdir"
record() { # <release line tag> [more lines]: the record the release carries, unsigned
	rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"
	printf 'release %s\npodman v6.2.0\nrecipe abc\n' "$1" > "$FAKE_DIR/components.txt"
}
sign() { # [seed file]: signs the record in place
	( read -r GLYNDOR_RELEASE_ED25519_KEY < "${1:-$WORK/keys/ed25519.seed}"; export GLYNDOR_RELEASE_ED25519_KEY
		python3 -I "$HERE/.github/scripts/release/sign.py" "$FAKE_DIR/components.txt" > /dev/null )
}
out="$WORK/released"
ask() { # <tag>: the first form, with the output file holding something old
	printf 'stale\n' > "$out"
	tag="$(FAKE_LATEST="$1" "$SCRIPT" "$out" 2> "$WORK/err")"; rc=$?
}
refused() { # <description> <message>: failed, said why, and left no record behind
	check "$1: fails and says why" "1 1" "$rc $(grep -c -- "$2" "$WORK/err")"
	check "$1: leaves no record, not even the old one, and prints no tag" "absent " "$([ -e "$out" ] && echo present || echo absent) $tag"
}

tag="$(FAKE_LATEST="" "$SCRIPT" "$out" 2>/dev/null)"; rc=$?
check "no release yet: succeeds, and names no tag" "0 " "$rc $tag"
check "and leaves the file empty" 0 "$(wc -c < "$out")"

record v6.2.0+r2; sign; ask v6.2.0+r2
check "a signed record of the release is accepted" "0 v6.2.0+r2" "$rc $tag"
check "and is what the file holds" "release v6.2.0+r2 podman v6.2.0 recipe abc" "$(paste -sd' ' "$out")"
record v6.2.0+r2; sign; printf 'x\n' >> "$FAKE_DIR/components.txt"; ask v6.2.0+r2
refused "a record changed after it was signed" "does not verify"
record v6.2.0+r2; sign "$WORK/other/ed25519.seed"; ask v6.2.0+r2
refused "a record signed with another key" "does not verify"
record v6.2.0+r2; ask v6.2.0+r2
refused "a record with no signature" "carries no readable signature"
record v6.2.0+r1; sign; ask v6.2.0+r2
refused "a signed record put on another release" "does not name that release"
record v6.2.0+r2; printf 'release v6.2.0+r1\n' >> "$FAKE_DIR/components.txt"; sign; ask v6.2.0+r2
refused "a signed record that names two releases" "does not name that release"
record v6.2.0+r2; sign; rm "$FAKE_DIR/components.txt"; ask v6.2.0+r2
refused "a release with no components.txt" "has no readable components.txt"
record v6.2.0+r2; printf 'recipe abc\n' > "$FAKE_DIR/components.txt"; sign; ask v6.2.0+r2
refused "a record that names no podman version" "names no podman version"
record v6.2.0+r2; sign; FAKE_DOWNLOAD_FAILS=components.txt.sig ask v6.2.0+r2
refused "a signature that cannot be downloaded" "carries no readable signature"
record v6.2.0+r2; sign; FAKE_VIEW_FAILS=1 ask v6.2.0+r2
check "the first form does not ask for the assets, as for the watchdog" "0 v6.2.0+r2" "$rc $tag"
record v6.2.0+r9; ask v6.2.0+r9; FAKE_PRE=v6.2.0+r9 record v6.2.0+r2; sign; FAKE_PRE=v6.2.0+r9 ask v6.2.0+r2
check "a pre-release is not the release that is read" "0 v6.2.0+r2" "$rc $tag"

# Without an interpreter that has the library, one is made here; when that cannot be done, nothing is read.
mkdir -p "$WORK/nopython"; printf '#!/bin/sh\nexit 1\n' > "$WORK/nopython/python3"; chmod +x "$WORK/nopython/python3"
record v6.2.0+r2; sign; RELEASE_VERIFY_PYTHON='' PATH="$WORK/nopython:$PATH" ask v6.2.0+r2
refused "a signing library that cannot be installed" "could not be installed"

# --- the second signature, once the anchor holds a key -------------------------------------------
printf 'QUJD\n' > "$root/keyring/glyndor-release-mldsa65.b64"
record v6.2.0+r2; sign; ask v6.2.0+r2
refused "a record without the second signature once the anchor holds a key" "no readable components.txt.mldsa65.sig"
# A second signature that downloads and does not verify is refused, not only one that is missing.
cp "$HERE/tests/release/fixtures/mldsa65/vector.mldsa65.b64" "$root/keyring/glyndor-release-mldsa65.b64"
record v6.2.0+r2; sign
head -c 3308 /dev/zero > "$FAKE_DIR/components.txt.mldsa65.sig"
ask v6.2.0+r2
refused "a downloaded but malformed second signature" "does not verify"
printf '# no second key yet\n' > "$root/keyring/glyndor-release-mldsa65.b64"

# --- the asset list, for whether the newest release carries a second signature -----
assets="$WORK/assets"
printf 'stale.mldsa65.sig\n' > "$assets"
FAKE_VIEW_FAILS=1 "$SCRIPT" --assets "" "$assets" >/dev/null 2>&1; rc=$?
check "no release yet: succeeds without asking, and leaves the asset file empty" "0 0" "$rc $(wc -c < "$assets")"
printf 'stale.mldsa65.sig\n' > "$assets"
FAKE_LATEST="v6.2.0+r3" FAKE_ASSETS='components.txt\npodman_6.2.0+r3_amd64.deb\npodman_6.2.0+r3_amd64.deb.mldsa65.sig\n' \
	"$SCRIPT" --assets v6.2.0+r3 "$assets" >/dev/null 2>&1; rc=$?
check "a release: the asset file holds the names of its assets, and nothing older" \
	"0 components.txt podman_6.2.0+r3_amd64.deb podman_6.2.0+r3_amd64.deb.mldsa65.sig" "$rc $(paste -sd' ' "$assets")"
FAKE_LATEST="v6.2.0+r3" FAKE_VIEW_FAILS=1 "$SCRIPT" --assets v6.2.0+r3 "$assets" 2>"$WORK/err" >/dev/null; rc=$?
check "an asset list that cannot be read fails, and says so" "1 1" "$rc $(grep -c 'cannot list the assets of release v6.2.0+r3' "$WORK/err")"
FAKE_LATEST="v6.2.0+r3" FAKE_ASSETS='' "$SCRIPT" --assets v6.2.0+r3 "$assets" 2>"$WORK/err" >/dev/null; rc=$?
check "an empty asset list fails: it is not read as a release with no second signature" "1 1" \
	"$rc $(grep -c 'does not name components.txt' "$WORK/err")"

"$SCRIPT" >/dev/null 2>&1; check "no argument fails" 1 "$?"
"$SCRIPT" "$out" "$assets" >/dev/null 2>&1; check "the old two-file form is a usage error, not a silent half" 2 "$?"
"$SCRIPT" --assets v6.2.0 >/dev/null 2>&1; check "--assets without its file is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
