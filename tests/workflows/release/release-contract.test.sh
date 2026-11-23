#!/usr/bin/env bash
#
# Tests for the controls of .github/workflows/release.yml that no script suite can
# see go: only main publishes, the second (ML-DSA-65) signature is required once its
# public key is committed, it is verified against that key and published, and the
# provenance attestation is made. The two steps that sign and publish are read from
# the workflow and run here, under the shell GitHub uses, with fakes for python and
# gh; the guard and the attestation are rules read from the workflow file, run once on
# the real file and once on a copy that breaks each of them.
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

# violations <rule> [workflow-dir]: prints one line per violation of a rule over
# release.yml. The directory is a parameter so a rule can run on a copy that breaks
# it. A rule that cannot run prints "rule failed", so a crash is never read as none.
violations() {
	python3 - "$1" "${2:-$HERE/.github/workflows}/release.yml" 2>&1 <<'PY' || echo "rule failed"
import re, sys, yaml

rule, path = sys.argv[1:3]
with open(path) as fh:
    jobs = yaml.safe_load(fh)["jobs"]
GUARD = "github.ref == 'refs/heads/main'"
# publish never runs in a rehearsal, and the check that ends a rehearsal runs only in one.
EXTRA = {"publish": " && needs.plan.outputs.dry_run != 'true'", "rehearsal": " && needs.plan.outputs.dry_run == 'true'"}

if rule == "guard":
    # plan, sign and publish always, and any other job that can write to the repository:
    # a dispatch from a branch must not tag or sign an unreviewed commit.
    needs = {"plan", "sign", "publish", "rehearsal"}
    for name, cfg in jobs.items():
        perms = cfg.get("permissions") or {}
        if perms.get("contents") == "write" or perms.get("attestations") == "write":
            needs.add(name)
    for name in sorted(needs):
        if name not in jobs:
            print(f"job {name} is missing")
        elif str(jobs[name].get("if", "")).strip() not in (GUARD, GUARD + EXTRA.get(name, "\0")):
            print(f"job {name} does not carry the main-only guard")
elif rule == "rehearsal":
    # A rehearsal reads no signing secret, attests nothing and creates nothing: the one job that
    # can hold a signing secret is sign, and it gives the step an empty string in a rehearsal.
    import json
    for name, cfg in jobs.items():
        text = json.dumps(cfg)
        if "secrets.GLYNDOR_RELEASE" in text and name != "sign":
            print(f"{name} reads a signing secret")
    sign_env = [s.get("env") or {} for s in jobs["sign"]["steps"]]
    keys = [e for e in sign_env if any("secrets.GLYNDOR_RELEASE" in str(v) for v in e.values())]
    if len(keys) != 1:
        print(f"{len(keys)} steps of sign read the signing secrets, expected 1")
    else:
        for k, v in keys[0].items():
            if "secrets.GLYNDOR_RELEASE" in str(v) and not str(v).startswith("${{ needs.plan.outputs.dry_run != 'true' && "):
                print(f"{k} is read in a rehearsal")
    r = jobs.get("rehearsal")
    if r is None:
        print("job rehearsal is missing")
    else:
        if (r.get("permissions") or {}) != {"contents": "read"}:
            print("rehearsal holds more than contents: read")
        for s in r["steps"]:
            if "attest" in str(s.get("uses", "")) or "release create" in str(s.get("run", "")):
                print("rehearsal attests or creates a release")
            if str(s.get("uses", "")).startswith("actions/checkout@") and "ref" in (s.get("with") or {}):
                print("rehearsal checks out a ref that is not the event's own")
elif rule == "attest":
    cfg = jobs["publish"]
    steps = cfg["steps"]
    perms = cfg.get("permissions") or {}
    for p in ("id-token", "attestations"):
        if perms.get(p) != "write":
            print(f"publish lacks {p}: write, which the attestation needs")
    hits = [i for i, s in enumerate(steps)
            if re.fullmatch(r"actions/attest-build-provenance@[0-9a-f]{40}", str(s.get("uses", "")))]
    if len(hits) != 1:
        print(f"{len(hits)} steps attest the build provenance, expected 1")
    else:
        i = hits[0]
        subject = str((steps[i].get("with") or {}).get("subject-path", ""))
        if not subject.endswith("/signed/podman_*.deb"):
            print(f"the attestation subject is {subject!r}, not the .deb packages")
        verify = [n for n, s in enumerate(steps) if s.get("name") == "Verify every signature against the published keys"]
        create = [n for n, s in enumerate(steps) if s.get("name") == "Create the release"]
        if not verify or not create or not (verify[0] < i < create[0]):
            print("the attestation is not between the verification of the signatures and the release")
        if any("GLYNDOR_RELEASE" in str(x.get("env", "")) for x in [cfg] + steps):
            print("publish holds a signing key")
elif rule == "previous":
    # What the plan read about the newest release reaches the signing step as it was
    # read: a literal there would decide the downgrade rule for every run.
    want = "${{ steps.p.outputs.previous_mldsa }}"
    if str((jobs["plan"].get("outputs") or {}).get("previous_mldsa", "")) != want:
        print(f"plan does not hand on previous_mldsa as {want}")
    want = "${{ needs.plan.outputs.previous_mldsa }}"
    if str((jobs["sign"].get("env") or {}).get("PREVIOUS_MLDSA", "")) != want:
        print(f"sign does not take PREVIOUS_MLDSA from {want}")
elif rule == "isolation":
    # What a job that signs or publishes may do with what the build jobs handed it. The
    # artifacts are third-party output: they are downloaded one by name, outside the
    # checkout, and nothing that runs while a key is in the environment installs, imports
    # or starts an interpreter in the directory that holds them.
    held = re.compile(r"secrets\.GLYNDOR_RELEASE")
    for name in ("sign", "publish"):
        for step in jobs[name]["steps"]:
            label = step.get("name") or step.get("uses") or "a step"
            with_ = step.get("with") or {}
            if "merge-multiple" in with_:
                print(f"{name}: {label} merges artifacts into one directory")
            if str(step.get("uses", "")).startswith("actions/download-artifact"):
                if not with_.get("name"):
                    print(f"{name}: a download takes no artifact by name")
                if not str(with_.get("path", "")).startswith("${{ runner.temp }}/"):
                    print(f"{name}: a download goes somewhere other than runner.temp")
            run = str(step.get("run", ""))
            keyed = bool(held.search(str(step.get("env", ""))))
            if keyed and re.search(r"\bpip\b|-m venv", run):
                print(f"{name}: {label} installs or builds an environment with a key in the environment")
            if keyed and re.search(r"working-directory", str(step)) and re.search(r"built|signed|stage", str(step.get("working-directory", ""))):
                print(f"{name}: {label} runs in a directory that holds artifacts")
            for line in run.split("\n"):
                code = line.split("#", 1)[0]
                if re.search(r'(?:"\$py"|\bpython3?)\s', code) and " -I " not in code:
                    print(f"{name}: {label} starts Python without -I: {code.strip()[:60]}")
PY
}

# sabotage <file> <old> <new> <dir>: a copy of the workflows in <dir> with <old>
# replaced by <new> exactly once. A replacement that changes nothing is reported, so
# a rule is never judged against a copy that still has the control in it.
sabotage() {
	rm -rf "$4"; mkdir -p "$4"; cp "$HERE"/.github/workflows/*.yml "$4/"
	python3 - "$4/$1" "$2" "$3" <<'PY' || echo "SABOTAGE INERT"
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(f"{old!r} occurs {text.count(old)} times in {path}")
open(path, "w").write(text.replace(old, new))
PY
}

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
check "build runs only when the plan says there is something to build" "needs.plan.outputs.build == 'true'" "$(gate release.yml build if)"
check "build waits for the plan" "plan" "$(gate release.yml build needs)"
check "sign waits for the plan and for the build of every architecture" "build,plan" "$(gate release.yml sign needs)"
check "publish waits for the plan and for the signing" "plan,sign" "$(gate release.yml publish needs)"

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
		rm -rf "$S/art" "$S/rt" "$WS" "$S/calls" "$S/calls.keys" "$S/out"; mkdir -p "$S/art" "$S/rt/stage" "$S/rt/signvenv/bin" "$WS/keyring"
		: > "$S/calls"; : > "$S/out"
		# The environment the step before made, and the packages the check of the download let through.
		cp "$S/venv-python" "$S/rt/signvenv/bin/python"
		touch "$S/rt/stage/podman_6.2.0_amd64.deb" "$S/rt/stage/podman_6.2.0_arm64.deb"
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
			GITHUB_OUTPUT="$S/out" CALLS="$S/calls" TAG=v6.2.0 \
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
		check "$state anchor, no secret: each package is signed first" "2" "$(signed)"
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
	check "and nothing is verified that was not signed first" "sign verify sign verify" \
		"$(sed -n 's#^-I [^ ]*/\(sign\|verify-sig\)\.py .*#\1#p' "$S/calls" | sed 's/-sig//' | paste -sd' ')"
	sign keyed ""
	check "a committed key and no secret: refused" "1" "$rc"
	check "and it says the secret is what is missing" 1 "$(says 'holds a public key and GLYNDOR_RELEASE_MLDSA65_KEY is not configured')"
	check "and nothing is signed" 0 "$(signed)"
	sign empty a-seed
	check "a secret and no committed key: the second signature is still required of the verifier" \
		"0 1 1" "$rc $(calls "$(verify_line "$S/rt/stage/podman_6.2.0_amd64.deb" --require-mldsa)") $(calls "$(verify_line "$S/rt/stage/podman_6.2.0_arm64.deb" --require-mldsa)")"
	sign committed ""
	check "the anchor this repository commits, no secret: the packages go through" "0 2" "$rc $(signed)"
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

# --- release.yml, sign and publish: what is downloaded is never run or merged --------
check "no step merges artifacts, downloads one without a name, or runs Python unisolated beside a key" "" "$(violations isolation)"
sabotage release.yml "          name: deb-amd64
" "          pattern: deb-*
          merge-multiple: true
" "$BAD" >/dev/null 2>&1
check "a download that merges artifacts is named" "sign: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 merges artifacts into one directory
sign: a download takes no artifact by name" "$(violations isolation "$BAD")"
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
check "the two checks of the downloads run before any step that holds a key, in the job that signs" "Check what was built is exactly the packages of the tag|Install the signing library|Sign every package, then verify against the published key" \
	"$(python3 - "$HERE/.github/workflows/release.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["sign"]["steps"]
names = [s.get("name") for s in steps if s.get("name")]
print("|".join(names))
PY
)"

# --- release.yml, publish: the step that creates the release ---------------------
R="$WORK/create"
if step release.yml publish "name=Create the release" "$R"; then
	check "the release step's run block has no expression in it" 0 "$(grep -c '\${{' "$R/run.sh")"
	mkdir -p "$R/bin"
	printf '#!/bin/sh\necho "$*" >> "$CALLS"\n' > "$R/bin/gh"
	chmod +x "$R/bin/gh"
	SHA=0123456789abcdef0123456789abcdef01234567
	release() { # <REQUIRE_MLDSA, may be empty> [TAG] [SHA]
		rm -rf "$R/art" "$R/calls" "$R/rt"; mkdir "$R/art" "$R/rt"; : > "$R/calls"
		local a
		for a in amd64 arm64; do : > "$R/art/podman_6.2.0+r2_$a.deb"; : > "$R/art/podman_6.2.0+r2_$a.deb.sig"; done
		run_step "$R" "$R/art" PATH="$R/bin:$PATH" CALLS="$R/calls" RUNNER_TEMP="$R/rt" TAG="${2-v6.2.0+r2}" SHA="${3-$SHA}" \
			PODMAN=v6.2.0 NETAVARK=v2.1.0 AARDVARK=v2.1.3 RECIPE=r1 REQUIRE_MLDSA="$1" \
			GH_TOKEN=a-token GH_REPO=owner/repo
	}
	assets() { grep "^release create v6.2.0+r2 --target $SHA " "$R/calls" | sed 's/.*before signing\. //; s#'"$R"'/rt/##'; }
	base="podman_6.2.0+r2_amd64.deb podman_6.2.0+r2_amd64.deb.sig podman_6.2.0+r2_arm64.deb podman_6.2.0+r2_arm64.deb.sig"
	mldsa="podman_6.2.0+r2_amd64.deb podman_6.2.0+r2_amd64.deb.sig podman_6.2.0+r2_amd64.deb.mldsa65.sig podman_6.2.0+r2_arm64.deb podman_6.2.0+r2_arm64.deb.sig podman_6.2.0+r2_arm64.deb.mldsa65.sig"

	release true
	check "a required second signature: the release is created on the commit the plan fixed, from the exact names" "0 1 $mldsa components.txt" \
		"$rc $(grep -c '^release create' "$R/calls") $(assets)"
	check "and it creates no tag by another way: the commit is the target, not a branch" 0 "$(grep -c -e '--target main' -e '--target v' "$R/calls")"
	check "and components.txt lists the four components the plan compares" "podman v6.2.0|netavark v2.1.0|aardvark-dns v2.1.3|recipe r1" \
		"$(paste -sd'|' "$R/rt/components.txt")"
	release false
	check "none required: the release carries the assets it always has" "0 $base components.txt" "$rc $(assets)"
	release ""
	check "a step output that is empty requires nothing" "0 $base components.txt" "$rc $(assets)"
	for bad in main v6.2 'v6.2.0+r2; touch x' 'v6.2.0+r2
x'; do
		release false "$bad"
		check "the tag '$(printf '%s' "$bad" | head -n 1)' is not a version: nothing is created" "1 0" "$rc $(grep -c '^release create' "$R/calls")"
	done
	for bad in abc123 main "${SHA}0" "${SHA%?}" ""; do
		release false v6.2.0+r2 "$bad"
		check "the commit '$bad' is not a full commit id: nothing is created" "1 0" "$rc $(grep -c '^release create' "$R/calls")"
	done
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that creates the release"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
