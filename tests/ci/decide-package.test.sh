#!/usr/bin/env bash
#
# Tests for scripts/ci/decide-package.sh: every path that has to build the native packages
# does, nothing else does, and anything it cannot read builds them.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/ci/decide-package.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

decide() { printf "$1" | bash "$SCRIPT"; }

for p in \
	scripts/package/build-payload.sh \
	scripts/package/rpm/podman.spec \
	scripts/package/images/fc45/Dockerfile \
	scripts/package/distros.txt \
	scripts/upstream/verify-tag.sh \
	scripts/verify/package-state.sh \
	scripts/build/install-common-config.sh \
	keyring/podman/containers.gpg \
	.github/workflows/reusable-package.yml \
	.github/workflows/package-check.yml \
	.github/workflows/release.yml \
	scripts/ci/decide-package.sh; do
	check "builds for $p" true "$(decide "$p\n")"
done

for p in \
	README.md \
	docs/x.md \
	tests/package/x.test.sh \
	.github/workflows/tests.yml \
	.github/workflows/build-check.yml \
	.github/workflows/reusable-build.yml \
	scripts/build/build-deb.sh \
	scripts/build/Dockerfile \
	scripts/verify/smoke-test.sh \
	scripts/quality/check-secrets.sh \
	scripts/ci/decide-build.sh \
	scripts/packager/a.sh; do
	check "does not build for $p" false "$(decide "$p\n")"
done

check "one matching path among others" true "$(decide 'README.md\ndocs/x.md\nscripts/package/distros.txt\n')"
check "matching path first" true "$(decide 'scripts/package/distros.txt\nREADME.md\n')"
check "only paths that do not match" false "$(decide 'README.md\ndocs/x.md\ntests/ci/x.test.sh\n')"
check "no trailing newline" true "$(decide 'README.md\nscripts/package/distros.txt')"
check "leading ./ is ignored" true "$(decide './scripts/package/distros.txt\n')"

check "empty input" true "$(decide '')"
check "only a newline" true "$(decide '\n')"
check "only blank lines" true "$(decide '\n\n\n')"
check "a quoted path" true "$(decide 'README.md\n"docs/caf\\303\\251.md"\n')"
out="$(bash "$SCRIPT" < /dev/null)"; check "stdin closed" true "$out"
out="$(bash "$SCRIPT" < "$HERE/tests/ci" 2>/dev/null)"; check "unreadable stdin" true "$out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
