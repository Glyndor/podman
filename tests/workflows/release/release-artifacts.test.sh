#!/usr/bin/env bash
#
# Tests for how the job that signs takes what the build jobs made: downloaded by the id and digest the build reported,
# never merged or run, checked against the list of artifacts of the run, and against the sha256 the build took before
# anything ran the package. The two steps are read from the workflow and run with a fake gh; the rules over the
# downloads run once on the real file and once on a copy that breaks each.
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

BAD="$WORK/bad"
# --- release.yml, sign and publish: what is downloaded is never run or merged --------
check "the signer takes each package by an id of this run with its digest checked, the publisher the signed set by name, and nothing runs Python unisolated beside a key" "" "$(violations isolation)"
sabotage release.yml "          artifact-ids: \${{ needs.build-amd64.outputs.artifact_id }}
" "          pattern: deb-*
" "$BAD" >/dev/null 2>&1
check "a signer that takes artifacts by pattern is named" "sign: a download takes no artifact by the id a build job reported
sign: a download takes artifacts by name or pattern
sign: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 merges artifacts into one directory" "$(violations isolation "$BAD")"
sabotage release.yml "          artifact-ids: \${{ needs.build-amd64.outputs.artifact_id }}
" "          artifact-ids: 123
" "$BAD" >/dev/null 2>&1
check "an id that no build job reported is named" "sign: a download takes no artifact by the id a build job reported" "$(violations isolation "$BAD")"
sabotage release.yml "          merge-multiple: true
          digest-mismatch: error
          path: \${{ runner.temp }}/built/deb-amd64" "          merge-multiple: true
          path: \${{ runner.temp }}/built/deb-amd64" "$BAD" >/dev/null 2>&1
check "a download that does not fail on a different digest is named" "sign: a download does not fail on a digest that differs" "$(violations isolation "$BAD")"
sabotage release.yml "          name: signed
          path: \${{ runner.temp }}/signed
      - name: Check the signed set is exactly the packages of the tag, with the signatures that were required
        run: bash scripts/release/check-artifacts.sh signed \"\$TAG\" \"\$RUNNER_TEMP/signed\" \"\$REQUIRE_MLDSA\"
      - name: Verify every signature against the published keys" "          pattern: signed*
          merge-multiple: true
          path: \${{ runner.temp }}/signed
      - name: Check the signed set is exactly the packages of the tag, with the signatures that were required
        run: bash scripts/release/check-artifacts.sh signed \"\$TAG\" \"\$RUNNER_TEMP/signed\" \"\$REQUIRE_MLDSA\"
      - name: Verify every signature against the published keys" "$BAD" >/dev/null 2>&1
check "a publish that takes artifacts by pattern and merges them is named" "publish: a download takes no artifact by name
publish: a download takes more than one artifact
publish: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 merges artifacts into one directory" "$(violations isolation "$BAD")"
sabotage release.yml "          path: \${{ runner.temp }}/built/deb-arm64" "          path: \${{ github.workspace }}/deb-arm64" "$BAD" >/dev/null 2>&1
check "a download into the checkout is named" "sign: a download goes somewhere other than runner.temp" "$(violations isolation "$BAD")"
sabotage release.yml '"$py" -I "$GITHUB_WORKSPACE/.github/scripts/release/sign.py" "$deb"' '"$py" "$GITHUB_WORKSPACE/.github/scripts/release/sign.py" "$deb"' "$BAD" >/dev/null 2>&1
check "Python started without -I beside a key is named" "sign: Sign every package, then verify against the published key starts Python without -I: \"\$py\" \"\$GITHUB_WORKSPACE/.github/scripts/release/sign.py\" \"\$" "$(violations isolation "$BAD")"
sabotage release.yml '          py="$RUNNER_TEMP/signvenv/bin/python"
' '          py="$RUNNER_TEMP/signvenv/bin/python"
          "$py" -I -m pip install pip
' "$BAD" >/dev/null 2>&1
check "an install with a key in the environment is named" "sign: Sign every package, then verify against the published key installs or builds an environment with a key in the environment" "$(violations isolation "$BAD")"
sabotage release.yml "        working-directory: \${{ runner.temp }}/tools
        env:
          GLYNDOR_RELEASE_ED25519_KEY" "        working-directory: \${{ runner.temp }}/stage
        env:
          GLYNDOR_RELEASE_ED25519_KEY" "$BAD" >/dev/null 2>&1
check "a signing step that runs in the directory of the packages is named" "sign: Sign every package, then verify against the published key runs in a directory that holds artifacts" "$(violations isolation "$BAD")"
check "the two checks of the downloads run before any step that holds a key, in the job that signs" "Check the artifact of each package is the one the build uploaded|Check each package is the file the build hashed before it ran|Check what was built is exactly the packages of the tag|Install the signing library|Sign every package, then verify against the published key" \
	"$(python3 - "$HERE/.github/workflows/release.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["sign"]["steps"]
names = [s.get("name") for s in steps if s.get("name")]
print("|".join(names))
PY
)"

# --- release.yml, sign: the packages are the artifacts the build jobs reported ----------------------
# gh answers with the artifacts of the run, one "<name> <id> <expired> <commit> <digest>" per line, tab separated. The
# build jobs reported an id and a digest each; the signer refuses when the list does not show that id with that digest,
# made for the commit the plan fixed, under the name deb-<arch>, and unexpired.
I="$WORK/ids"
if step release.yml sign "name=Check the artifact of each package is the one the build uploaded" "$I"; then
	mkdir -p "$I/bin"
	printf '#!/bin/sh\n[ -z "$FAKE_GH_FAILS" ] || exit 1\nprintf "%%b" "$ROWS"\n' > "$I/bin/gh"; chmod +x "$I/bin/gh"
	SHA=0123456789abcdef0123456789abcdef01234567
	H1="$(printf 'a%.0s' $(seq 1 64))"; H2="$(printf 'b%.0s' $(seq 1 64))"
	good="deb-amd64\t11\tfalse\t$SHA\tsha256:$H1\ndeb-arm64\t12\tfalse\t$SHA\tsha256:$H2\nsigned\t13\tfalse\t$SHA\tsha256:$H2\n"
	ids() { # <rows> [VAR=value]...: runs the step as the build jobs reported 11/H1 and 12/H2; sets $rc and $out
		local rows="$1"; shift
		run_step "$I" "$WORK" PATH="$I/bin:$PATH" ROWS="$rows" GH_TOKEN=a-token GH_REPO=owner/repo RUN_ID=77 SHA="$SHA" \
			AMD64_ID=11 AMD64_DIGEST="sha256:$H1" ARM64_ID=12 ARM64_DIGEST="$H2" "$@"
	}
	ids "$good"
	check "ids and digests the build jobs reported, in the list of this run, for the commit, unexpired: it goes on" "0 1" "$rc $(says 'deb-arm64 is artifact 12')"
	ids "$good" AMD64_ID=13
	check "an id that is another artifact of the run (signed, by the name) is refused" "1 1" "$rc $(says 'the artifact 13 is called signed, not deb-amd64')"
	ids "$good" ARM64_ID=99
	check "an id the run does not list is refused" "1 1" "$rc $(says 'does not list exactly one artifact with the id 99')"
	ids "$good" AMD64_ID=
	check "no id reported by the build is refused" "1 1" "$rc $(says "reported the artifact id ''")"
	ids "$good" "AMD64_ID=11; id"
	check "an id that is not a number is refused" "1 1" "$rc $(says 'not a number')"
	ids "$good" AMD64_DIGEST="sha256:$H2"
	check "a digest that differs from the one the build reported is refused" "1 1" "$rc $(says "gives deb-amd64 the digest 'sha256:$H1'")"
	ids "$good" ARM64_DIGEST=not-a-digest
	check "a digest the build reported that is no sha256 is refused" "1 1" "$rc $(says 'not a sha256')"
	ids "deb-amd64\t11\ttrue\t$SHA\tsha256:$H1\ndeb-arm64\t12\tfalse\t$SHA\tsha256:$H2\n"
	check "an artifact that has expired is refused" "1 1" "$rc $(says 'deb-amd64 has expired')"
	ids "deb-amd64\t11\tfalse\t$SHA\tsha256:$H1\ndeb-arm64\t12\tfalse\tfeedfacefeedfacefeedfacefeedfacefeedface\tsha256:$H2\n"
	check "an artifact made for another commit is refused" "1 1" "$rc $(says 'deb-arm64 was made for feedface')"
	ids "$good$good"
	check "two artifacts with the id are refused" "1 1" "$rc $(says 'does not list exactly one artifact with the id 11')"
	ids "$good" FAKE_GH_FAILS=1
	check "a list that cannot be read stops the step" "stopped" "$([ "$rc" -ne 0 ] && echo stopped)"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that checks the artifacts against what the build reported"
fi

# The file inside the artifact is the one the build hashed before any test ran it.
Q="$WORK/hash"
if step release.yml sign "name=Check each package is the file the build hashed before it ran" "$Q"; then
	built() { # <amd64 content> <arm64 content>: a directory of downloads, and the hash of what the build saw
		rm -rf "$Q/rt"; mkdir -p "$Q/rt/built/deb-amd64" "$Q/rt/built/deb-arm64"
		printf '%s' "$1" > "$Q/rt/built/deb-amd64/podman_6.2.0_amd64.deb"; printf '%s' "$2" > "$Q/rt/built/deb-arm64/podman_6.2.0_arm64.deb"
		A_SUM="$(printf '%s' amd | sha256sum | cut -d' ' -f1)"; R_SUM="$(printf '%s' arm | sha256sum | cut -d' ' -f1)"
	}
	hashed() { run_step "$Q" "$WORK" RUNNER_TEMP="$Q/rt" TAG=v6.2.0 AMD64_SHA256="$A_SUM" ARM64_SHA256="$R_SUM" "$@"; }
	built amd arm; hashed
	check "packages that are the files the build hashed go on" "0" "$rc"
	built amd other; hashed
	check "a package that is not the file that was hashed is refused, and which one" "1 1" "$rc $(says 'podman_6.2.0_arm64.deb is')"
	built amd arm; hashed AMD64_SHA256=
	check "a build that reported no hash is refused" "1 1" "$rc $(says "reported the sha256 ''")"
	built amd arm; rm "$Q/rt/built/deb-amd64/podman_6.2.0_amd64.deb"; ln -s "$Q/rt/built/deb-arm64/podman_6.2.0_arm64.deb" "$Q/rt/built/deb-amd64/podman_6.2.0_amd64.deb"; hashed
	check "a package that is a link is refused" "1 1" "$rc $(says 'is not a regular file')"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that compares each package with the hash of the build"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
