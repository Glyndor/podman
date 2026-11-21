#!/usr/bin/env bash
#
# Tests for the switch that requires the second (ML-DSA-65) signature of every release:
# the line "required" in keyring/second-signature-required, read by the signing step of
# .github/workflows/release.yml. The step is read from the workflow and run here, as in
# release-contract.test.sh, with a python whose verify-sig.py knows one row of the real
# verifier's table: a second signature that is required and absent is refused. The rest
# of that table is tested in tests/release/. What is held here is what the step itself
# decides: while the switch is on, an anchor with no key, a missing secret or a missing
# second signature stops the run, and a switch it cannot read stops it too.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

S="$WORK/sign"
if step release.yml publish secret=GLYNDOR_RELEASE_ED25519_KEY "$S"; then
	mkdir -p "$S/bin"
	cat > "$S/venv-python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case " $* " in
	*"/verify-sig.py "*" --require-mldsa "*)
		sig=""; prev=""
		for a in "$@"; do [ "$prev" = --mldsa-sig ] && sig="$a"; prev="$a"; done
		[ -e "$sig" ] || { echo "no ML-DSA-65 signature ($sig); the hybrid release signature is required"; exit 1; } ;;
esac
exit 0
PY
	cat > "$S/bin/python3" <<'PY'
#!/bin/sh
[ "$1 $2" = "-m venv" ] || exit 99
mkdir -p "$3/bin" && cp "$FAKE_PYTHON" "$3/bin/python" && chmod +x "$3/bin/python"
PY
	chmod +x "$S/venv-python" "$S/bin/python3"
	WS="$S/ws"
	SWITCH="$WS/keyring/second-signature-required"
	head='# Whether every release must carry the ML-DSA-65 signature.\n'
	# sign <switch: on|off|committed|missing|raw> <anchor: keyed|empty> <secret> <second signature: present|absent>
	# With "raw", $RAW is written to the switch with printf %b.
	sign() {
		rm -rf "$S/art" "$S/rt" "$WS"; mkdir -p "$S/art" "$WS/keyring"; : > "$S/calls"; : > "$S/out"
		local i
		for i in 1 2; do
			: > "$S/art/podman_6.2.0_arch$i.deb"
			[ "$4" = absent ] || : > "$S/art/podman_6.2.0_arch$i.deb.mldsa65.sig"
		done
		case "$1" in
			on) printf "${head}required\n" > "$SWITCH" ;;
			off) printf "$head" > "$SWITCH" ;;
			committed) cp "$HERE/keyring/second-signature-required" "$SWITCH" ;;
			raw) printf '%b' "$RAW" > "$SWITCH" ;;
			missing) ;;
		esac
		case "$2" in
			keyed) printf '# keys\nAAAAAAAAAAAAAAAA\n' > "$WS/keyring/glyndor-release-mldsa65.b64" ;;
			empty) printf '# keys\n' > "$WS/keyring/glyndor-release-mldsa65.b64" ;;
		esac
		cp "$HERE/keyring/glyndor-release-ed25519.b64" "$WS/keyring/"
		run_step "$S" "$S/art" PATH="$S/bin:$PATH" RUNNER_TEMP="$S/rt" GITHUB_WORKSPACE="$WS" \
			GITHUB_OUTPUT="$S/out" CALLS="$S/calls" FAKE_PYTHON="$S/venv-python" \
			GLYNDOR_RELEASE_ED25519_KEY=an-ed25519-seed GLYNDOR_RELEASE_MLDSA65_KEY="$3" PREVIOUS_MLDSA=false
	}
	signed() { grep -c 'sign.py ' "$S/calls"; }
	required() { grep -c 'verify-sig.py .* --require-mldsa$' "$S/calls"; }

	# --- every combination, against the rule written out ---------------------------
	# The step stops by itself when the switch is on and the anchor has no key, and
	# when the anchor has a key and the secret is missing. Otherwise the second
	# signature is required when the switch is on or the secret is set, and a required
	# one that is absent is refused by the verifier.
	wrong=""; n=0
	for sw in on off; do for an in keyed empty; do for se in a-seed ""; do for sig in present absent; do
		if { [ "$sw" = on ] && [ "$an" = empty ]; } || { [ "$an" = keyed ] && [ -z "$se" ]; }; then
			want="1 stopped"
		else
			req=0; { [ "$sw" = on ] || [ -n "$se" ]; } && req=2
			# A refusal stops the loop at the first package.
			rc_want=0; [ "$req" -gt 0 ] && [ "$sig" = absent ] && { rc_want=1; req=1; }
			want="$rc_want $req"
		fi
		sign "$sw" "$an" "$se" "$sig"
		if [ "$(signed)" -eq 0 ]; then got="$rc stopped"; else got="$rc $(required)"; fi
		[ "$got" = "$want" ] || wrong="$wrong $sw/$an/${se:-nosecret}/$sig=($got)"
		n=$((n + 1))
	done; done; done; done
	check "all $n combinations of the switch, the anchor, the secret and the second signature" "" "${wrong# }"

	# --- each refusal, by what it says ----------------------------------------------
	sign on empty a-seed present
	check "switch on, an anchor with no key: stopped before signing, and it says why" "1 0 1" \
		"$rc $(signed) $(says 'keyring/second-signature-required requires the second signature and keyring/glyndor-release-mldsa65.b64 holds no key')"
	sign on keyed "" present
	check "switch on, no secret: stopped for the secret" "1 0 1" "$rc $(signed) $(says 'GLYNDOR_RELEASE_MLDSA65_KEY is not configured')"
	sign on keyed a-seed absent
	check "switch on, no second signature: refused by the verifier, as required" "1 1" \
		"$rc $(says 'the hybrid release signature is required')"
	sign on keyed a-seed present
	check "switch on, key, secret and signature: through, and the release is told it is required" "0 2 1" \
		"$rc $(required) $(grep -c -x require_mldsa=true "$S/out")"

	# --- the switch as committed --------------------------------------------------
	sign committed empty "" absent
	check "the switch this repository commits requires nothing: the release of today goes through" "0 2 0 1" \
		"$rc $(signed) $(required) $(grep -c -x require_mldsa=false "$S/out")"
	check "and it says so in a comment, with no line that would switch it on" 0 "$(grep -c -x 'required' "$HERE/keyring/second-signature-required")"
	sign missing empty "" absent
	check "no switch file at all: stopped, not read as off" "1 0 1" "$rc $(signed) $(says 'second-signature-required is missing; refusing to publish')"

	# --- a switch that is not understood is not read as off ------------------------
	unread() { # <desc> <content> <what it says>
		RAW="$2" sign raw empty "" absent
		check "$1: stopped before signing, and it says why" "1 0 1" "$rc $(signed) $(says "$3")"
	}
	line="which is neither a comment nor 'required'"
	unread "a misspelt line" "${head}requried\n" "holds the line 'requried', $line"
	unread "the line indented" "${head}  required\n" "holds the line '  required', $line"
	unread "the line with a comment after it" "${head}required # since 2027\n" "holds the line 'required # since 2027', $line"
	unread "another word" "${head}no\n" "holds the line 'no', $line"
	bytes='keyring/second-signature-required holds a byte that is neither printable ASCII nor a line feed'
	unread "the line behind a carriage return" "${head}required\r\n" "$bytes"
	unread "a NUL in a comment" "# a comment\0# another\n" "$bytes"
	unread "a byte past ASCII" "${head}# \200\n" "$bytes"
	RAW="${head}\n   # an indented comment\n\nrequired" sign raw keyed a-seed present
	check "blank lines, an indented comment and the line with no line feed after it: read as on" "0 2" "$rc $(required)"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that holds the signing key"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
