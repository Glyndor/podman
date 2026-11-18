#!/usr/bin/env bash
#
# Tests for scripts/verify/refuse-test.sh: the argument contract, and how it copes
# with a release whose archive has moved. The real refusal needs root inside an
# Ubuntu 22.04 container and is exercised by the release workflow.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/refuse-test.sh"
pass=0; fail=0

check() { # <desc> <want-exit> <got-exit>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want exit $2, got $3)"; fi
}

"$SCRIPT" >/dev/null 2>&1; rc=$?
check "no arguments fails" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
"$SCRIPT" /nonexistent.deb >/dev/null 2>&1; check "missing deb fails with 2" 2 "$?"

# The release this runs on is old on purpose. When its archive has moved to
# old-releases, the first apt-get update fails and the script must point apt there
# and carry on, instead of stopping every release.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
cat > "$WORK/bin/apt-get" <<'APT'
#!/usr/bin/env bash
case "$1" in
	update)
		echo update >> "$APT_LOG"
		if [ "${APT_UPDATE_FAILS_ONCE:-0}" = 1 ] && [ "$(grep -c update "$APT_LOG")" -eq 1 ]; then exit 100; fi
		exit 0 ;;
	install)
		echo "podman : Depends: libc6 (>= 2.39) but 2.35-0ubuntu3 is to be installed"; exit 100 ;;
esac
APT
chmod +x "$WORK/bin/apt-get"
printf 'x' > "$WORK/p.deb"
printf 'deb http://archive.ubuntu.com/ubuntu jammy main\ndeb http://security.ubuntu.com/ubuntu jammy-security main\n' > "$WORK/sources.list"

PATH="$WORK/bin:$PATH" APT_LOG="$WORK/log1" APT_SOURCES="$WORK/sources.list" "$SCRIPT" "$WORK/p.deb" >/dev/null 2>&1
check "a refusal naming libc6 passes" 0 "$?"
check "an archive that answers is left alone" 0 "$(grep -c old-releases "$WORK/sources.list")"

PATH="$WORK/bin:$PATH" APT_UPDATE_FAILS_ONCE=1 APT_LOG="$WORK/log2" APT_SOURCES="$WORK/sources.list" "$SCRIPT" "$WORK/p.deb" >/dev/null 2>&1
check "an archive that moved to old-releases still passes" 0 "$?"
check "and apt is pointed at old-releases" 2 "$(grep -c 'old-releases.ubuntu.com' "$WORK/sources.list")"
check "after trying the live archive first" 2 "$(grep -c update "$WORK/log2")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
