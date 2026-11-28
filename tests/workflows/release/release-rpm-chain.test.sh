#!/usr/bin/env bash
#
# The way of the rpm packages from the job that builds them to the release, run end to end from the steps of the
# workflows: each leg stages and hashes its packages and reports them (reusable-package.yml), the gathering takes only
# what was reported and hashes the set (reusable-rpm.yml), and the job that signs checks the set it downloaded against
# that hash, requires it to be exactly the release, signs every file and the check of the signed set passes
# (release.yml). Then the same chain with one thing wrong, at each place: nothing past it goes on. The artifacts are
# directories, gh is a fake that lists them, and the signing is real, with keys made for the run.
# Requires: python3 with the cryptography library (Ed25519).
# shellcheck disable=SC2016 # the fake gh and the search for expressions hold literal $ on purpose
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
# shellcheck source=tests/lib/rpm-set.sh
. "$HERE/tests/lib/rpm-set.sh"

V=6.2.1+r6
SHA=0123456789abcdef0123456789abcdef01234567
LEGS="$(bash "$HERE/scripts/release/rpm/names.sh" legs)"
H="$WORK/hash"; R="$WORK/report"; G="$WORK/ids"; C="$WORK/collect"
found() {
	step reusable-package.yml build "name=Check what was built is exactly the packages of the leg, and hash each" "$H" || return 1
	step reusable-package.yml build "name=Report the artifact and the hashes of the leg" "$R" || return 1
	step reusable-rpm.yml gather "name=Check the artifact of each leg is the one its build uploaded" "$G" || return 1
	step reusable-rpm.yml gather "name=Check each package is the file its build hashed, and gather those of the release" "$C"
}
found || { echo "FAIL  a step of the chain is not in its workflow"; echo "0 passed, 1 failed"; exit 1; }
for s in "$H" "$R" "$G" "$C"; do check "the run block of $(basename "$s") has no expression in it" 0 "$(grep -c '\${{' "$s/run.sh")"; done

mkdir -p "$G/bin"
printf '#!/bin/sh\ncat "$ROWS"\n' > "$G/bin/gh"; chmod +x "$G/bin/gh"

# build_legs: every leg builds, stages, hashes and reports, as the matrix does. The outputs of the legs are merged by
# name, which is what Actions does with them, into $WORK/legs.json; each artifact is a directory in $WORK/artifacts.
build_legs() {
	rm -rf "$WORK/artifacts" "$WORK/rows" "$WORK/outputs"; mkdir -p "$WORK/artifacts"; : > "$WORK/rows"; : > "$WORK/outputs"
	local id arch n=100 rt out line digest
	while read -r id arch; do
		n=$((n + 1)); rt="$WORK/rt-$id-$arch"; rm -rf "$rt"; mkdir -p "$rt/out"
		while IFS= read -r line; do fake_rpm "$rt/out/$line" "$line of $arch"; done <<< "$(bash "$HERE/scripts/release/rpm/names.sh" leg "$V" "$id" "$arch")"
		: > "$rt/github-output"
		run_step "$H" "$HERE" RUNNER_TEMP="$rt" VERSION="$V" ID="$id" ARCH="$arch" GITHUB_OUTPUT="$rt/github-output"
		[ "$rc" -eq 0 ] || { echo "$out"; return 1; }
		cp -r "$rt/staged" "$WORK/artifacts/rpm-$id-$arch"
		digest="$(printf '%s' "$id-$arch" | sha256sum | cut -d' ' -f1)"
		: > "$rt/report"
		run_step "$R" "$HERE" ID="$id" ARCH="$arch" ARTIFACT_ID="$n" ARTIFACT_DIGEST="$digest" \
			FILES="$(sed -n 's/^files=//p' "$rt/github-output")" GITHUB_OUTPUT="$rt/report"
		[ "$rc" -eq 0 ] || { echo "$out"; return 1; }
		cat "$rt/report" >> "$WORK/outputs"
		printf 'rpm-%s-%s\t%s\tfalse\t%s\tsha256:%s\n' "$id" "$arch" "$n" "$SHA" "$digest" >> "$WORK/rows"
	done <<< "$LEGS"
	python3 -I -c '
import json, sys
print(json.dumps(dict(line.rstrip("\n").split("=", 1) for line in open(sys.argv[1]))))' "$WORK/outputs" > "$WORK/legs.json"
}
gather_ids() {
	rm -rf "$WORK/gt"; mkdir "$WORK/gt"; : > "$WORK/gt/out"
	run_step "$G" "$HERE" PATH="$G/bin:$PATH" ROWS="$WORK/rows" RUNNER_TEMP="$WORK/gt" GITHUB_OUTPUT="$WORK/gt/out" \
		PREFIX=rpm LEGS="$(cat "$WORK/legs.json")" COMMIT="$SHA" GH_REPO=o/r RUN_ID=1 GH_TOKEN=t
}
gather_set() {
	rm -rf "$WORK/gt/legs" "$WORK/gt/set"; cp -r "$WORK/artifacts" "$WORK/gt/legs"; : > "$WORK/gt/collect"
	run_step "$C" "$HERE" RUNNER_TEMP="$WORK/gt" VERSION="$V" PREFIX=rpm LEGS="$(cat "$WORK/legs.json")" GITHUB_OUTPUT="$WORK/gt/collect"
}

build_legs || { fail=$((fail + 1)); echo "FAIL  the legs do not build"; }
check "every leg reports one output of its own" "14 14" "$(grep -c . "$WORK/outputs") $(jq 'keys | length' "$WORK/legs.json")"
gather_ids
check "the gathering takes the artifacts the legs reported, in order" "0 ids=$(seq -s, 101 114)" "$rc $(cat "$WORK/gt/out")"
gather_set
check "and gathers the forty packages of the release, with their hash" "0 40 1" \
	"$rc $(find "$WORK/gt/set" -type f | wc -l) $(grep -c -x -E 'manifest=[0-9a-f]{64}' "$WORK/gt/collect")"
MANIFEST="$(sed -n 's/^manifest=//p' "$WORK/gt/collect")"

# --- the job that signs, with the set as downloaded -------------------------------------------------
mkdir -p "$WORK/venv/bin"; ln -s "$(command -v python3)" "$WORK/venv/bin/python"
python3 -I "$HERE/.github/scripts/release/dry-run-keys.py" "$WORK/keys" > /dev/null
printf '# none\n' > "$WORK/mldsa.b64"
Q="$WORK/qhash"; S="$WORK/stage"
step release.yml sign "name=Check each package is the file the build hashed before it ran" "$Q"
step release.yml sign "name=Check what was built is exactly the packages of the tag" "$S"
downloaded() {
	rm -rf "$WORK/sr"; mkdir -p "$WORK/sr/built/deb-amd64" "$WORK/sr/built/deb-arm64"
	local a root
	for a in amd64 arm64; do
		root="$WORK/sr/root-$a"; mkdir -p "$root/DEBIAN"
		printf 'Package: podman\nVersion: %s\nArchitecture: %s\nMaintainer: x <x@example.org>\nDescription: x\n' "$V" "$a" > "$root/DEBIAN/control"
		dpkg-deb --root-owner-group -Znone --build "$root" "$WORK/sr/built/deb-$a/podman_${V}_$a.deb" > /dev/null
	done
	cp -r "$WORK/gt/set" "$WORK/sr/built/rpm"
}
checks() {
	run_step "$Q" "$HERE" RUNNER_TEMP="$WORK/sr" TAG="v$V" RPM_MANIFEST="$MANIFEST" \
		AMD64_SHA256="$(sha256sum "$WORK/sr/built/deb-amd64/podman_${V}_amd64.deb" | cut -d' ' -f1)" \
		ARM64_SHA256="$(sha256sum "$WORK/sr/built/deb-arm64/podman_${V}_arm64.deb" | cut -d' ' -f1)"
	hashes=$rc
	run_step "$S" "$HERE" RUNNER_TEMP="$WORK/sr" TAG="v$V"
}
downloaded; checks
check "the set that was gathered passes both checks of the signer, and is staged with the .deb" "0 0 42" "$hashes $rc $(find "$WORK/sr/stage" -type f | wc -l)"
signed_set() { TAG="v$V" PODMAN=v6.2.1 NETAVARK=v2.1.0 AARDVARK=v2.1.0 RECIPE=abc bash "$HERE/scripts/release/signed-set.sh" "$@"; }
sign_all() {
	signed_set components "$WORK/sr/stage/components.txt" && signed_set sums "$WORK/sr/stage" || return 1
	( read -r GLYNDOR_RELEASE_ED25519_KEY < "$WORK/keys/ed25519.seed"; export GLYNDOR_RELEASE_ED25519_KEY
		while IFS= read -r n; do python3 -I "$HERE/.github/scripts/release/sign.py" "$WORK/sr/stage/$n" > /dev/null || exit 1; done <<< "$(signed_set list)" )
}
sign_all
verified() { out="$(signed_set verify "$WORK/sr/stage" "$WORK/keys/ed25519.b64" "$WORK/mldsa.b64" false "$WORK/venv" 2>&1)"; rc=$?; }
exact() { out="$(bash "$HERE/scripts/release/check-artifacts.sh" signed "v$V" "$WORK/sr/stage" false 2>&1)"; rc=$?; }
exact; check "everything signed is exactly the release" 0 "$rc"
verified; check "and every signature and the list of hashes verify" 0 "$rc"
check "and every asset the release would attach is there" 0 \
	"$(cd "$WORK/sr/stage" && signed_set assets false | while IFS= read -r a; do [ -f "$a" ] || echo "$a"; done | grep -c .)"

# --- one thing wrong at each place: nothing past it goes on -----------------------------------------
build_legs; jq -c 'del(.tumbleweed_x86_64)' "$WORK/legs.json" > "$WORK/new"; mv "$WORK/new" "$WORK/legs.json"; gather_ids
check "a distribution that did not report: the gathering stops, nothing is downloaded" "1 0" "$rc $(grep -c ^ids= "$WORK/gt/out")"
build_legs; gather_ids; rm "$WORK/artifacts/rpm-el9-aarch64"/podmansh-*; gather_set
check "a package a leg lost after hashing it: nothing is gathered" "1 0" "$rc $(grep -c ^manifest= "$WORK/gt/collect")"
build_legs; gather_ids; printf x >> "$(find "$WORK/artifacts/rpm-el10-x86_64" -name 'podman-[0-9]*')"; gather_set
check "a package changed after it was hashed: nothing is gathered" "1 0" "$rc $(grep -c ^manifest= "$WORK/gt/collect")"
build_legs; gather_ids; gather_set; MANIFEST="$(sed -n 's/^manifest=//p' "$WORK/gt/collect")"
downloaded; printf x >> "$(find "$WORK/sr/built/rpm" -name 'podman-[0-9]*' | head -n 1)"; checks
check "a package changed between the gathering and the signer: the hash check refuses it" 1 "$hashes"
downloaded; rm "$(find "$WORK/sr/built/rpm" -name 'crun-*' | head -n 1)"; checks
check "a package missing at the signer: both checks refuse, and nothing is staged" "1 1 0" "$hashes $rc $([ -d "$WORK/sr/stage" ] && find "$WORK/sr/stage" -type f | wc -l || echo 0)"
downloaded; checks; sign_all; rm "$(find "$WORK/sr/stage" -name '*.rpm' | head -n 1)"; exact
check "a signed set that lacks a package is not the release" 1 "$rc"
verified; check "and does not verify" 1 "$rc"
downloaded; checks; sign_all; rm "$(find "$WORK/sr/stage" -name '*.rpm.sig' | head -n 1)"; exact
check "nor one that lacks a signature" 1 "$rc"
verified; check "which does not verify either" 1 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
