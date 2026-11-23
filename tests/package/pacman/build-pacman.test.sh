#!/usr/bin/env bash
#
# Tests for scripts/package/pacman/build-pacman.sh with a makepkg, a su and a useradd that write down what
# they were asked: the packages are made by an unprivileged user from the PKGBUILD of this repository,
# with the version and the versions of the payload in the environment, and a payload that was not
# built, or a version without its revision, is refused. What makepkg does with the PKGBUILD is held by the
# real run in the workflow, on Arch Linux.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/pacman/build-pacman.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin" "$WORK/payload"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/useradd"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/id"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/chown"
# su runs the command line it is given as the current user
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -c) shift; exec bash -c "$1" ;; esac; shift; done\n' > "$WORK/bin/su"
cat > "$WORK/bin/makepkg" <<'MP'
#!/bin/sh
echo "makepkg $* | version=$GL_VERSION payload=$GL_PAYLOAD nv=$GL_NETAVARK aa=$GL_AARDVARK cc=$GL_COMMON packager=$PACKAGER" >> "$CALLS"
echo "$PWD" >> "$CALLS"
: > "$PKGDEST/podman-$GL_VERSION-1-x86_64.pkg.tar.zst"; : > "$PKGDEST/podman-docker-$GL_VERSION-1-any.pkg.tar.zst"
MP
chmod +x "$WORK/bin"/*
printf 'NETAVARK_VERSION=2.1.0\nAARDVARK_VERSION=2.1.3\nCOMMON_VERSION=0.70.0\n' > "$WORK/payload/facts.env"
export CALLS="$WORK/calls"
PATH="$WORK/bin:$PATH"
run() { : > "$CALLS"; rm -rf "$WORK/out"; out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

run "$WORK/payload" 6.2.0+r12 "$WORK/out"
check "a build succeeds" 0 "$rc"
check "both packages are collected" "podman-6.2.0+r12-1-x86_64.pkg.tar.zst podman-docker-6.2.0+r12-1-any.pkg.tar.zst" "$(ls "$WORK/out" | LC_ALL=C sort | sed -n "2p;1p" | paste -sd' ')"
check "makepkg is told the version, the payload and what the payload carries" \
	"version=6.2.0+r12 payload=$WORK/payload nv=2.1.0 aa=2.1.3 cc=0.70.0" "$(sed -n 1p "$CALLS" | sed 's/.*| //; s/ packager=.*//')"
check "the packager is the Glyndor address" "packager=Glyndor <noreply@glyndor.net>" "$(sed -n 1p "$CALLS" | sed 's/.*| version=[^ ]* payload=[^ ]* nv=[^ ]* aa=[^ ]* cc=[^ ]* //')"
check "it runs without a dependency check, forced and without prompts" 1 "$(sed -n 1p "$CALLS" | grep -c 'makepkg --nodeps --force --noconfirm')"
check "it runs from a directory with a copy of the PKGBUILD of this repository" 1 "$(sed -n 2p "$CALLS" | grep -c '/build$')"

for bad in 6.2.0 6.2.0+r 6.2.0-1 v6.2.0+r1 '6.2.0+r1 x'; do
	run "$WORK/payload" "$bad" "$WORK/out"
	check "the version '$bad' is refused" "1 1" "$rc $(says 'bad version, expected X.Y.Z+rR')"
done
mkdir "$WORK/empty"
run "$WORK/empty" 6.2.0+r1 "$WORK/out"; check "a payload that was not built is refused" "1 1" "$rc $(says 'the payload was not built')"
for key in NETAVARK_VERSION AARDVARK_VERSION COMMON_VERSION; do
	mkdir -p "$WORK/p2"; grep -v "^$key" "$WORK/payload/facts.env" > "$WORK/p2/facts.env"
	run "$WORK/p2" 6.2.0+r1 "$WORK/out"; check "a payload whose facts lack $key is refused" "1 1" "$rc $(says "facts.env has no $key")"
done
"$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"
# The PKGBUILD itself: the checks that need makepkg are the real run's, these are what its text must say.
PKG="$HERE/scripts/package/pacman/PKGBUILD"
check "the PKGBUILD makes a split package of podman and podman-docker, for x86_64" "pkgbase=podman pkgname=(podman podman-docker) arch=(x86_64)" \
	"$(grep -E '^(pkgbase|pkgname|arch)=' "$PKG" | paste -sd' ')"
check "it replaces and conflicts with netavark and aardvark-dns, and not with containers-common, which owns /etc/containers" "1 0" \
	"$(grep -c -E 'conflicts=\(netavark aardvark-dns\)' "$PKG") $(grep -c -E '^[[:space:]]*(conflicts|replaces)=.*containers-common' "$PKG")"
check "it depends on containers-common at the version of the release or newer, and ships none of its files" "1 1" \
	"$(grep -c 'containers-common>=1:$GL_COMMON' "$PKG") $(grep -c 'rm -rf "$pkgdir/usr/share/containers"' "$PKG")"
check "podman-docker needs podman at the version and release of the same build" 1 "$(grep -c 'depends=("podman=$pkgver-$pkgrel")' "$PKG")"
check "the libraries the binaries link are read from them before the package functions, and declared" "1 1" "$(grep -c '_sodeps+=(' "$PKG") $(grep -c '"${_sodeps\[@\]}"' "$PKG")"

check "everything under /etc of the payload is declared as backup, for podman and for podman-docker" "2 2" \
	"$(grep -c '_backup\(_docker\)\?+=(' "$PKG") $(grep -c 'backup=("${_backup' "$PKG")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
