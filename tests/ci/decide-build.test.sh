#!/usr/bin/env bash
#
# Tests for scripts/ci/decide-build.sh: every path that has to trigger a build
# does, nothing else does, and anything it cannot read triggers one.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/ci/decide-build.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

decide() { printf "$1" | bash "$SCRIPT"; }

# One path per pattern the script lists.
for p in \
	scripts/build/Dockerfile \
	scripts/build/build-deb.sh \
	scripts/verify/smoke-test.sh \
	scripts/upstream/verify-tag.sh \
	keyring/podman/containers.gpg \
	.github/workflows/reusable-build.yml \
	.github/workflows/build-check.yml \
	.github/workflows/release.yml \
	scripts/ci/decide-build.sh; do
	check "builds for $p" true "$(decide "$p\n")"
done

# Paths that cannot change what the build produces.
for p in \
	README.md \
	docs/x.md \
	tests/quality/x.test.sh \
	tests/build/build-deb.test.sh \
	.github/workflows/tests.yml \
	.github/workflows/watchdog.yml \
	scripts/quality/check-secrets.sh \
	scripts/monitoring/delivery-lag.sh \
	scripts/ci/other.sh \
	scripts/buildx/a.sh \
	keyring/upgrade/postinst; do
	check "does not build for $p" false "$(decide "$p\n")"
done

check "one matching path among others" true "$(decide 'README.md\ndocs/x.md\nscripts/build/Dockerfile\n')"
check "matching path first" true "$(decide 'scripts/verify/refuse-test.sh\nREADME.md\n')"
check "only paths that do not match" false "$(decide 'README.md\ndocs/x.md\ntests/ci/x.test.sh\n')"
check "no trailing newline" true "$(decide 'README.md\nscripts/build/Dockerfile')"
check "leading ./ is ignored" true "$(decide './scripts/build/Dockerfile\n')"

# Fails open.
check "empty input" true "$(decide '')"
check "only a newline" true "$(decide '\n')"
check "only blank lines" true "$(decide '\n\n\n')"
check "a quoted path" true "$(decide 'README.md\n"docs/caf\\303\\251.md"\n')"
out="$(bash "$SCRIPT" < /dev/null)"; check "stdin closed" true "$out"
out="$(bash "$SCRIPT" < "$HERE/tests/ci" 2>/dev/null)"; check "unreadable stdin" true "$out"

# Spaces are part of the path.
check "path with spaces, no match" false "$(decide 'docs/a b.md\nREADME file.md\n')"
check "path with spaces, match" true "$(decide 'docs/a b.md\nscripts/build/a b.sh\n')"
check "a space before a prefix is not the prefix" false "$(decide ' scripts/build/Dockerfile\n')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
