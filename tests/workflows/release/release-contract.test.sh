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
check "sign waits for the plan, for the build of every architecture and for the rpm packages" "build-amd64,build-arm64,plan,rpm" "$(gate release.yml sign needs)"
check "the rpm packages are built only when the plan says there is something to build" "'true' == needs.plan.outputs.build" "$(gate release.yml rpm if | sed 's/^\${{ *//; s/ *}}$//')"
check "and wait for the plan" "plan" "$(gate release.yml rpm needs)"
# The rpm job is a call: what it builds, and that it is the release's set and not a check, is in what it passes.
rpm_call() { # [workflow dir]: the workflow the rpm job calls, whether it is a release, and what each input is fed from
	python3 - "${1:-$HERE/.github/workflows}/release.yml" <<'PY' 2>&1 || echo "rule failed"
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["rpm"]
print(job.get("uses"), job.get("with", {}).get("upload"), job.get("permissions"))
for key, value in sorted(job.get("with", {}).items()):
    if key != "upload" and str(value) != "${{ needs.plan.outputs." + key + " }}":
        print(f"{key} is {value}, not what the plan resolved")
PY
}
check "the release builds the rpm packages with the shared workflow, as a release, from what the plan resolved, with no write" \
	"./.github/workflows/reusable-rpm.yml \${{ true && true }} {'contents': 'read', 'actions': 'read'}" "$(rpm_call)"
sabotage release.yml "      upload: \${{ true && true }}

  # The job that holds the signing keys." "      upload: false

  # The job that holds the signing keys." "$BAD" >/dev/null 2>&1
check "packages made as a check are named" "./.github/workflows/reusable-rpm.yml False {'contents': 'read', 'actions': 'read'}" "$(rpm_call "$BAD")"
sabotage release.yml "      aardvark_sha: \${{ needs.plan.outputs.aardvark_sha }}
      upload: \${{ true && true }}

  # The job that holds the signing keys." "      aardvark_sha: \${{ needs.plan.outputs.podman_sha }}
      upload: \${{ true && true }}

  # The job that holds the signing keys." "$BAD" >/dev/null 2>&1
check "packages built from another commit than the plan resolved are named" \
	"aardvark_sha is \${{ needs.plan.outputs.podman_sha }}, not what the plan resolved" "$(rpm_call "$BAD" | sed -n '2,$p')"
check "publish waits for the plan, for the signing and for the upgrade test of the published package" "config-upgrade,plan,sign" "$(gate release.yml publish needs)"
# A release missing a package is not published: every job that signs or publishes runs only when what it waits for
# succeeded, so none of them carries a condition that would run it whatever the rpm packages ended as.
check "sign runs whatever its needs ended as only if its condition says so, and it does not" "github.ref == 'refs/heads/main'" "$(gate release.yml sign if)"

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
          # Every file of the release, signatures included: the rpm channel verifies the attestation of each file it
          # downloads. The check of the signed set above left in this directory those files and no other.
          subject-path: \${{ runner.temp }}/signed/*
" "" "$BAD" >/dev/null 2>&1
check "a release without the attestation step is named" "0 steps attest the build provenance, expected 1" "$(violations attest "$BAD")"
sabotage release.yml "subject-path: \${{ runner.temp }}/signed/*" "subject-path: \${{ runner.temp }}/signed/podman_*.deb" "$BAD" >/dev/null 2>&1
check "an attestation that leaves the rpm packages and the signatures out is named" \
	"the attestation subject is '\${{ runner.temp }}/signed/podman_*.deb', not every file of the signed set" "$(violations attest "$BAD")"
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


# --- publish and rehearsal run the verification of the signed set, with the anchors each of them reads, and pass its
# failure on: the names of their steps say nothing about that.
for job in publish rehearsal; do
	case "$job" in
		publish) label="Verify every signature against the published keys" ;;
		rehearsal) label="Verify every signature against the throwaway keys" ;;
	esac
	V="$WORK/verify-$job"
	WS="$V/ws"
	RT="$V/rt"
	mkdir -p "$V/bin" "$WS/scripts/release"

	if ! step release.yml "$job" "name=$label" "$V"; then
		check "$job: verification step exists" 0 1
		continue
	fi

	cat > "$V/bin/python3" <<'PY'
#!/bin/sh
[ "$1 $2 $3" = "-I -m venv" ] || exit 97
mkdir -p "$4/bin"
printf '#!/bin/sh\nexit 0\n' > "$4/bin/python"
chmod +x "$4/bin/python"
PY
	cat > "$WS/scripts/release/signed-set.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$CALLS"
exit "$CHECK_EXIT"
SH
	chmod +x "$V/bin/python3" "$WS/scripts/release/signed-set.sh"

	for answer in 0 83; do
		rm -rf "$RT"; mkdir "$RT"
		: > "$V/calls"
		run_step "$V" "$WS" PATH="$V/bin:$PATH" \
			RUNNER_TEMP="$RT" GITHUB_WORKSPACE="$WS" \
			TAG=v6.2.0 REQUIRE_MLDSA=true \
			CALLS="$V/calls" CHECK_EXIT="$answer"
		check "$job: propagates verifier exit $answer" "$answer" "$rc"

		ed="$WS/keyring/glyndor-release-ed25519.b64"
		if [ "$job" = rehearsal ]; then
			ed="$RT/dry-public/ed25519.b64"
		fi
		want="verify|$RT/signed|$ed|$WS/keyring/glyndor-release-mldsa65.b64|true|$RT/verifyvenv"
		check "$job: verifies the signed set with the expected anchors" \
			"$want" "$(paste -sd'|' "$V/calls")"
	done
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
