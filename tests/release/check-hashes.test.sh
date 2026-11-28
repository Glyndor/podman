#!/usr/bin/env bash
#
# Tests for scripts/release/check-hashes.sh: before the job that signs reads anything, each .deb is the file its build
# job hashed and the rpm packages are the set the packaging gathered. The step of the workflow that calls it is run in
# tests/workflows/release/release-artifacts.test.sh; what is held here is each refusal of the script.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/release/check-hashes.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
# shellcheck source=tests/lib/rpm-set.sh
. "$HERE/tests/lib/rpm-set.sh"

fresh() {
	rm -rf "$WORK/b"; mkdir -p "$WORK/b/deb-amd64" "$WORK/b/deb-arm64"
	printf amd > "$WORK/b/deb-amd64/podman_6.2.0_amd64.deb"; printf arm > "$WORK/b/deb-arm64/podman_6.2.0_arm64.deb"
	fake_rpms "$WORK/b/rpm" 6.2.0
	A="$(printf amd | sha256sum | cut -d' ' -f1)"; R="$(printf arm | sha256sum | cut -d' ' -f1)"
	M="$(bash "$HERE/scripts/release/rpm/collect.sh" digest 6.2.0 "$WORK/b/rpm")"
}
run() { out="$(bash "$SCRIPT" "${TAG_:-v6.2.0}" "$WORK/b" "$A" "$R" "$M" 2>&1)"; rc=$?; }
refused() { check "$1" "1 1" "$rc $(says "$2")"; }

fresh; run
check "every file the one that was hashed: it goes on, and says so" "0 1" "$rc $(says 'are the files that were hashed')"
fresh; TAG_=main run; refused "a tag that is not a version" "is not a version"
fresh; A=""; run; refused "no hash of the amd64 package" "the build of amd64 reported the sha256 ''"
fresh; R=abc; run; refused "a hash of the arm64 package that is no sha256" "the build of arm64 reported the sha256 'abc'"
fresh; rm "$WORK/b/deb-amd64/podman_6.2.0_amd64.deb"; run; refused "a package that is not there" "is not a regular file"
fresh; printf x >> "$WORK/b/deb-arm64/podman_6.2.0_arm64.deb"; run; refused "a package that changed" "podman_6.2.0_arm64.deb is"
fresh; M=""; run; refused "no hash of the rpm packages" "reported the hash '' of the rpm packages"
fresh; rm "$WORK/b/rpm/podmansh-6.2.0+r1-1.glyndor.fc45.noarch.rpm"; run; refused "an rpm package that is not there" "the rpm packages cannot be hashed"
fresh; fake_rpm "$WORK/b/rpm/podmansh-6.2.0+r1-1.glyndor.fc45.noarch.rpm" other; run; refused "an rpm package that changed" "and the packaging gathered"
bash "$SCRIPT" v6.2.0 "$WORK/b" > /dev/null 2>&1; check "too few arguments is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
