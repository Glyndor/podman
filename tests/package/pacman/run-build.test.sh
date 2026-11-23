#!/usr/bin/env bash
#
# Tests for scripts/package/pacman/run-build.sh with fakes for pacman and for the scripts it calls: the
# steps of a build run in their order with the arguments each one needs, the short-name list is the
# one Arch's containers-common ships, and a repository that lacks a package, or a package with no
# list, stops the build.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/pacman/run-build.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir -p "$WORK/scripts/package/pacman" "$WORK/src/podman" "$WORK/bin" "$WORK/sn"
for s in package/require-tools.sh package/pacman/check-replacement.sh package/build-payload.sh package/pacman/build-pacman.sh; do
	printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n[ -z "$FAKE_FAIL" ] || [ "$FAKE_FAIL" != "%s" ] || exit 1\n' "$s" "$s" > "$WORK/scripts/$s"
done
echo '[aliases]' > "$WORK/sn/shortnames.conf"
cat > "$WORK/bin/pacman" <<'PM'
#!/bin/sh
echo "pacman $*" >> "$CALLS"
case "$1" in
	-Syu) [ -z "$FAKE_NO_PKG" ] || exit 1 ;;
	-Ql) [ -n "$FAKE_NO_SHORTNAMES" ] || echo "containers-common $SHORTNAMES" ;;
esac
exit 0
PM
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/git"
chmod +x "$WORK/bin/pacman" "$WORK/bin/git" "$WORK"/scripts/package/*.sh "$WORK"/scripts/package/pacman/*.sh
export CALLS="$WORK/calls" SHORTNAMES="$WORK/sn/shortnames.conf" GLYNDOR_SRC="$WORK/src" GLYNDOR_SCRIPTS="$WORK/scripts" HOME="$WORK/home"
mkdir "$HOME"
PATH="$WORK/bin:$PATH"
run() { : > "$CALLS"; out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

run 6.2.0+r12 "$WORK/out"
check "a build succeeds" 0 "$rc"
check "the system and the build dependencies are installed first, containers-common among them" 1 "$(grep -c '^pacman -Syu --noconfirm --needed base-devel git go rust protobuf libseccomp systemd gettext binutils file python man-db perl gawk sed grep containers-common' "$CALLS")"
check "then what requires podman is checked, then the payload is built, then the packages" "require-tools|check-replacement|build-payload|build-pacman" \
	"$(grep -v '^pacman' "$CALLS" | sed 's|^package/pacman/||; s|^package/||; s|\.sh .*||' | paste -sd'|')"
check "the payload is built from the three trees for Arch, with the list Arch ships" \
	"package/build-payload.sh $WORK/src/podman $WORK/src/netavark $WORK/src/aardvark $(grep build-payload "$CALLS" | awk '{print $5}') arch $WORK/sn/shortnames.conf" "$(grep build-payload "$CALLS")"
check "the packages are made from that payload, the version and the output directory" \
	"package/pacman/build-pacman.sh $(grep build-payload "$CALLS" | awk '{print $5}') 6.2.0+r12 $WORK/out" "$(grep build-pacman "$CALLS")"
FAKE_FAIL=package/require-tools.sh run 6.2.0+r12 "$WORK/out"; check "a build container that lacks a program the build runs stops the build before anything else" "1 0" "$rc $(grep -c check-replacement "$CALLS")"
FAKE_NO_PKG=1 run 6.2.0+r12 "$WORK/out"; check "a repository that lacks a package stops the build, and says so" "1 1" "$rc $(says 'lack a package the build requires')"
FAKE_FAIL=package/pacman/check-replacement.sh run 6.2.0+r12 "$WORK/out"; check "a package of Arch that is not covered stops the build before the payload" "1 0" "$rc $(grep -c build-payload "$CALLS")"
FAKE_FAIL=package/build-payload.sh run 6.2.0+r12 "$WORK/out"; check "a payload that fails stops the build before the packages" "1 0" "$rc $(grep -c build-pacman "$CALLS")"
FAKE_NO_SHORTNAMES=1 run 6.2.0+r12 "$WORK/out"; check "a containers-common with no short-name list stops the build" "1 1" "$rc $(says 'ships no shortnames.conf')"
"$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
