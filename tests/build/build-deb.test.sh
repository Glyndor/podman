#!/usr/bin/env bash
#
# Tests for scripts/build/build-deb.sh against a fake source tree: the .deb must
# be named for the package and version, and a malformed version is refused.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/build/build-deb.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/src"
printf 'all:\n\t@true\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/bin/podman\n' > "$WORK/src/Makefile"
arch="$(dpkg --print-architecture)"

deb="$("$SCRIPT" "$WORK/src" 6.2.0 "$WORK/out" 2>/dev/null)"
check "writes podman_<version>_<arch>.deb" "$WORK/out/podman_6.2.0_$arch.deb" "$deb"
check "control Package" podman "$(dpkg-deb -f "$deb" Package 2>/dev/null)"
check "control Version equals upstream" 6.2.0 "$(dpkg-deb -f "$deb" Version 2>/dev/null)"
check "binary is installed under /usr/bin" ./usr/bin/podman \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x './usr/bin/podman')"

"$SCRIPT" "$WORK/src" v6.2.0 "$WORK/out" >/dev/null 2>&1; check "version with a v is refused" 1 "$?"
"$SCRIPT" "$WORK/src" 6.2.0-rc1 "$WORK/out" >/dev/null 2>&1; check "pre-release version is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
