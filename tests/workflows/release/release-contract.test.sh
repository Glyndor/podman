#!/usr/bin/env bash
#
# Tests for the controls of .github/workflows/release.yml that are read from the workflow file and run once on the real
# file and once on a copy that breaks each of them: only main publishes, the order of the jobs, the environment that
# releases the keys, a rehearsal that reads no secret and publishes nothing, the provenance attestation, and what the plan
# read about the newest release reaching the signing step.
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
BAD="$WORK/bad"
GUARD_LINE="    if: github.ref == 'refs/heads/main'"
PUBLISH_GUARD_LINE="    if: github.ref == 'refs/heads/main' && needs.plan.outputs.dry_run != 'true'"
PUBLISH_COMMENT="    # always() above it) would otherwise publish from a branch. A rehearsal never gets here."

# --- only main publishes ----------------------------------------------------------
check "plan, sign and publish carry the main-only guard" "" "$(violations guard)"
sabotage release.yml "$GUARD_LINE
    # ubuntu-latest" "    # ubuntu-latest" "$BAD" >/dev/null 2>&1
check "a plan without the guard is named" "job plan does not carry the main-only guard" "$(violations guard "$BAD")"
sabotage release.yml "$PUBLISH_COMMENT
$PUBLISH_GUARD_LINE" "$PUBLISH_COMMENT" "$BAD" >/dev/null 2>&1
check "a publish without the guard is named" "job publish does not carry the main-only guard" "$(violations guard "$BAD")"
sabotage release.yml "    # always() above it) would otherwise sign on a branch.
$GUARD_LINE" "    # always() above it) would otherwise sign on a branch." "$BAD" >/dev/null 2>&1
check "a sign without the guard is named" "job sign does not carry the main-only guard" "$(violations guard "$BAD")"
sabotage release.yml "$PUBLISH_COMMENT
$PUBLISH_GUARD_LINE" "$PUBLISH_COMMENT
    if: github.ref == 'refs/heads/develop'" "$BAD" >/dev/null 2>&1
check "a guard on another branch is named" "job publish does not carry the main-only guard" "$(violations guard "$BAD")"

# --- which jobs run, and in which order -------------------------------------------
# A plan that finds nothing new says build=false. A build that ran anyway would take two
# runners, three clones and a compiler to be refused for an empty version; a publish that
# did not wait for the builds would start with no package to sign.
for arch in amd64 arm64; do
	# build-arm64 spells its guard as an expression, so that each call has text of its own in the mutation catalog.
	check "build-$arch runs only when the plan says there is something to build" "needs.plan.outputs.build == 'true'" "$(gate release.yml build-$arch if | sed 's/^\${{ *//; s/ *}}$//')"
	check "build-$arch waits for the plan" "plan" "$(gate release.yml build-$arch needs)"
done
check "sign waits for the plan and for the build of every architecture" "build-amd64,build-arm64,plan" "$(gate release.yml sign needs)"
check "publish waits for the plan, for the signing and for the upgrade test of the published package" "config-upgrade,plan,sign" "$(gate release.yml publish needs)"

# --- the keys are released by an environment, not by a line of this file --------------
check "every job that names a secret declares the environment release" "" "$(violations environment)"
sabotage release.yml "    environment: release
" "" "$BAD" >/dev/null 2>&1
check "a signing job with no environment is named" "release.yml: job sign names the secret GLYNDOR_RELEASE_ED25519_KEY and declares no environment" "$(violations environment "$BAD")"
sabotage release.yml "    environment: release
" "    environment: staging
" "$BAD" >/dev/null 2>&1
check "one with another environment is named" "release.yml: job sign names a secret and declares the environment 'staging', not release" "$(violations environment "$BAD")"
mkdir -p "$WORK/other"; cp "$HERE"/.github/workflows/*.yml "$WORK/other/"
python3 - "$WORK/other/tests.yml" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
i = t.index("    steps:\n")
open(p, "w").write(t[:i] + "    env:\n      TOKEN: ${{ secrets.SOME_TOKEN }}\n" + t[i:])
PY
check "a secret named by a job of another workflow with no environment is named too" "tests.yml: job $(python3 - "$WORK/other/tests.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
print(next(n for n, c in jobs.items() if "SOME_TOKEN" in str(c)), end="")
PY
) names the secret SOME_TOKEN and declares no environment" "$(violations environment "$WORK/other")"

# --- a rehearsal reads no secret and publishes nothing ---------------------------
check "only sign reads a signing secret, and not in a rehearsal; the rehearsal can only read" "" "$(violations rehearsal)"
sabotage release.yml "GLYNDOR_RELEASE_ED25519_KEY: \${{ needs.plan.outputs.dry_run != 'true' && secrets.GLYNDOR_RELEASE_ED25519_KEY || '' }}" "GLYNDOR_RELEASE_ED25519_KEY: \${{ secrets.GLYNDOR_RELEASE_ED25519_KEY }}" "$BAD" >/dev/null 2>&1
check "a signing secret that a rehearsal would read is named" "GLYNDOR_RELEASE_ED25519_KEY is read in a rehearsal" "$(violations rehearsal "$BAD")"
sabotage release.yml "    permissions:
      contents: read
    # Ceiling, not measured: a download of two packages and their verification." "    permissions:
      contents: write
    # Ceiling, not measured: a download of two packages and their verification." "$BAD" >/dev/null 2>&1
check "a rehearsal that can write is named" "rehearsal holds more than contents: read" "$(violations rehearsal "$BAD")"
sabotage release.yml "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: signed
          path: \${{ runner.temp }}/signed
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: dry-run-anchors" "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: \${{ needs.plan.outputs.sha }}
          persist-credentials: false
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: signed
          path: \${{ runner.temp }}/signed
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: dry-run-anchors" "$BAD" >/dev/null 2>&1
check "a rehearsal that checks out a commit an output named is named" "rehearsal checks out a ref that is not the event's own" "$(violations rehearsal "$BAD")"
check "a rehearsal does not publish: publish skips it" "github.ref == 'refs/heads/main' && needs.plan.outputs.dry_run != 'true'" "$(gate release.yml publish if)"
check "and the check that ends a rehearsal runs only in one" "github.ref == 'refs/heads/main' && needs.plan.outputs.dry_run == 'true'" "$(gate release.yml rehearsal if)"
check "and waits for the plan and the signing" "plan,sign" "$(gate release.yml rehearsal needs)"
# The last step of a rehearsal: a release called as the rehearsal's tag is an error, and none is the answer.
N="$WORK/norelease"
rc=0
if step release.yml rehearsal "name=Show that no release was made" "$N"; then
	mkdir -p "$N/bin"
	printf '#!/bin/sh\n[ "$1 $2" = "release view" ] && [ "$3" = "$FAKE_EXISTS" ] && exit 0\nexit 1\n' > "$N/bin/gh"; chmod +x "$N/bin/gh"
	run_step "$N" "$WORK" PATH="$N/bin:$PATH" TAG=v6.2.0+r999 FAKE_EXISTS=none
	check "a rehearsal that made no release says so" "0 1" "$rc $(says 'nothing attested, nothing published')"
	run_step "$N" "$WORK" PATH="$N/bin:$PATH" TAG=v6.2.0+r999 FAKE_EXISTS=v6.2.0+r999
	check "one that left a release behind is refused" "1 1" "$rc $(says 'exists after a rehearsal')"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the last step of the rehearsal"
fi

# --- the provenance attestation ---------------------------------------------------
check "the packages are attested between the verification of their signatures and the release" "" "$(violations attest)"
sabotage release.yml "      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
        with:
          subject-path: \${{ runner.temp }}/signed/podman_*.deb
" "" "$BAD" >/dev/null 2>&1
check "a release without the attestation step is named" "0 steps attest the build provenance, expected 1" "$(violations attest "$BAD")"
sabotage release.yml "subject-path: \${{ runner.temp }}/signed/podman_*.deb" "subject-path: \${{ runner.temp }}/signed/podman_*.deb.sig" "$BAD" >/dev/null 2>&1
check "an attestation of something other than the packages is named" \
	"the attestation subject is '\${{ runner.temp }}/signed/podman_*.deb.sig', not the .deb packages" "$(violations attest "$BAD")"
sabotage release.yml "      attestations: write
" "" "$BAD" >/dev/null 2>&1
check "a job that cannot write the attestation is named" "publish lacks attestations: write, which the attestation needs" "$(violations attest "$BAD")"
sabotage release.yml "          GLYNDOR_RELEASE_ED25519_KEY: \${{ secrets.GLYNDOR_RELEASE_ED25519_KEY }}" "          GLYNDOR_RELEASE_ED25519_KEY: \${{ secrets.GLYNDOR_RELEASE_ED25519_KEY }}" "$BAD" >/dev/null 2>&1
python3 - "$BAD/release.yml" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
head, sep, tail = t.partition("  publish:\n    name: Attest and publish")
tail = tail.replace("      REQUIRE_MLDSA:", "      GLYNDOR_RELEASE_ED25519_KEY: ${{ secrets.GLYNDOR_RELEASE_ED25519_KEY }}\n      REQUIRE_MLDSA:", 1)
open(p, "w").write(head + sep + tail)
PY
check "a job that publishes and holds a signing key is named" "publish holds a signing key" "$(violations attest "$BAD")"

# --- what the plan read about the newest release reaches the signing step ---------
check "previous_mldsa goes from the plan to the signing step untouched" "" "$(violations previous)"
sabotage release.yml "PREVIOUS_MLDSA: \${{ needs.plan.outputs.previous_mldsa }}" "PREVIOUS_MLDSA: false" "$BAD" >/dev/null 2>&1
check "a literal in its place is named" "sign does not take PREVIOUS_MLDSA from \${{ needs.plan.outputs.previous_mldsa }}" \
	"$(violations previous "$BAD")"
sabotage release.yml "previous_mldsa: \${{ steps.p.outputs.previous_mldsa }}" "previous_mldsa: 'false'" "$BAD" >/dev/null 2>&1
check "and so is one in the plan's outputs" "plan does not hand on previous_mldsa as \${{ steps.p.outputs.previous_mldsa }}" \
	"$(violations previous "$BAD")"


echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
