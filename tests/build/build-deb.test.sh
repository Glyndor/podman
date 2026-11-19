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

mkdir "$WORK/src" "$WORK/nv" "$WORK/aa"
mkdir -p "$WORK/passt/debian" "$WORK/passt/contrib/apparmor/abstractions"
printf 'passt (0.0~git20260728.f8df3f1-1~bpo13+1) trixie-backports; urgency=medium\n\n  * x\n\n -- X <x@example.org>  Tue, 28 Jul 2026 00:00:00 +0000\n' > "$WORK/passt/debian/changelog"
printf 'all:\n\t@true\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(prefix)/bin/passt\n' > "$WORK/passt/Makefile"
echo p > "$WORK/passt/contrib/apparmor/usr.bin.passt"; echo p > "$WORK/passt/contrib/apparmor/abstractions/passt"
mkdir -p "$WORK/mods/common/pkg/config" "$WORK/mods/common/pkg/seccomp" "$WORK/mods/common/rpm" "$WORK/mods/image" "$WORK/mods/storage"
printf 'module x\nrequire (\n\tgo.podman.io/common v0.70.0\n\tgo.podman.io/image/v5 v5.42.1\n\tgo.podman.io/storage v1.65.1\n)\n' > "$WORK/src/go.mod"
for f in common/pkg/config/containers.conf common/rpm/policy.json image/registries.conf image/default.yaml storage/storage.conf; do echo x > "$WORK/mods/$f"; done
echo '{"syscalls":[{"names":["futex_waitv"]}]}' > "$WORK/mods/common/pkg/seccomp/seccomp.json"
echo '[aliases]' > "$WORK/short.conf"
export GLYNDOR_PASST_SRC="$WORK/passt" GLYNDOR_MODULES_DIR="$WORK/mods" GLYNDOR_SHORTNAMES="$WORK/short.conf"
printf 'all:\n\t@echo "$(EXTRA_BUILDTAGS)" > %s/tags; echo "$$CGO_CFLAGS" > %s/cflags\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/bin/podman\ninstall.completions:\n\tinstall -D -m644 /dev/null $(DESTDIR)$(PREFIX)/share/bash-completion/completions/podman\n' "$WORK" "$WORK" > "$WORK/src/Makefile"
printf 'all:\n\t@echo "$(CARGO)" > %s/cargo-nv\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/libexec/podman/netavark\n' "$WORK" > "$WORK/nv/Makefile"; touch "$WORK/nv/Cargo.lock" "$WORK/aa/Cargo.lock"
printf '[package]\nname = "netavark"\nversion = "2.1.0"\n' > "$WORK/nv/Cargo.toml"
printf '[package]\nname = "aardvark-dns"\nversion = "2.1.3"\n' > "$WORK/aa/Cargo.toml"
printf 'all:\n\t@true\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/libexec/podman/aardvark-dns\n' > "$WORK/aa/Makefile"
build() { "$SCRIPT" "$WORK/src" "$WORK/nv" "$WORK/aa" "$@"; }
arch="$(dpkg --print-architecture)"

deb="$(build 6.2.0 "$WORK/out" 2>/dev/null)"
check "writes podman_<version>_<arch>.deb" "$WORK/out/podman_6.2.0_$arch.deb" "$deb"
check "control Package" podman "$(dpkg-deb -f "$deb" Package 2>/dev/null)"
check "control Version equals upstream" 6.2.0 "$(dpkg-deb -f "$deb" Version 2>/dev/null)"
check "binary is installed under /usr/bin" ./usr/bin/podman \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x './usr/bin/podman')"

for helper in netavark aardvark-dns; do
	check "$helper is installed under /usr/libexec/podman" "./usr/libexec/podman/$helper" \
		"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x "./usr/libexec/podman/$helper")"
done
check "replaces the distribution netavark, aardvark-dns and containers-common" "netavark, aardvark-dns, golang-github-containers-common, podman-remote, passt" "$(dpkg-deb -f "$deb" Conflicts 2>/dev/null)"
check "provides what Debian packages depend on, with the versions built" "netavark (= 2.1.0), aardvark-dns (= 2.1.3), golang-github-containers-common (= 0.70.0), podman-remote, passt (= 0.0~git20260728.f8df3f1-1~bpo13+1)" "$(dpkg-deb -f "$deb" Provides 2>/dev/null)"

check "the shell completions are installed" ./usr/share/bash-completion/completions/podman \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x './usr/share/bash-completion/completions/podman')"
check "criu is recommended, as Debian's package does, for checkpoint and restore" 1 \
	"$(dpkg-deb -f "$deb" Recommends 2>/dev/null | grep -c 'criu')"
check "the seccomp profile of this release is installed" ./usr/share/containers/seccomp.json \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x './usr/share/containers/seccomp.json')"
check "policy.json is a conffile under /etc/containers" ./etc/containers/policy.json \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x './etc/containers/policy.json')"
for f in ./usr/bin/passt ./usr/bin/pasta ./etc/apparmor.d/usr.bin.passt ./etc/apparmor.d/abstractions/passt; do
	check "passt ships $f" "$f" "$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x "$f")"
done
check "passt is no longer only recommended" 0 "$(dpkg-deb -f "$deb" Recommends 2>/dev/null | grep -c passt)"
check "the AppArmor profiles are loaded on configure" 1 "$(dpkg-deb -I "$deb" postinst 2>/dev/null | grep -c 'apparmor_parser -r')"
check "the distribution's containers-common is not depended on" 0 "$(dpkg-deb -f "$deb" Depends 2>/dev/null | grep -c 'golang-github-containers-common')"
check "an old crun is removed rather than left to fail" "crun (<< 1.21)" "$(dpkg-deb -f "$deb" Breaks 2>/dev/null)"
check "catatonit is required, as upstream does" 1 "$(dpkg-deb -f "$deb" Depends 2>/dev/null | grep -c 'catatonit')"
rm "$WORK/mods/common/pkg/seccomp/seccomp.json"
build 6.2.0 "$WORK/out2" >/dev/null 2>&1; rc=$?; check "a release without a seccomp profile is refused" 1 "$rc"
echo '{}' > "$WORK/mods/common/pkg/seccomp/seccomp.json"
case "$arch" in amd64) want_flag="-fcf-protection=full" ;; arm64) want_flag="-mbranch-protection=standard" ;; *) want_flag="" ;; esac
check "control-flow protection uses the flag this architecture has" 1 "$(grep -c -e "${want_flag:-.}" "$WORK/cflags" 2>/dev/null)"
check "cargo builds only what the lockfile of the tag says" "cargo --locked" "$(cat "$WORK/cargo-nv" 2>/dev/null)"
check "gpgme is replaced by Go's OpenPGP" containers_image_openpgp "$(cat "$WORK/tags" 2>/dev/null)"
check "old crun falls back to runc, and conmon has the floor upstream asks for" "conmon (>= 2.1.7), crun (>= 1.21) | runc" \
	"$(dpkg-deb -f "$deb" Depends 2>/dev/null | cut -d, -f1-2)"

check "libc6 carries the glibc the binaries need" 1 \
	"$(dpkg-deb -f "$deb" Depends 2>/dev/null | grep -c -E 'libc6 \(>= [0-9]+\.[0-9]+\)')"

check "a rebuild version is accepted" "6.2.0+r2" \
	"$(dpkg-deb -f "$(build 6.2.0+r2 "$WORK/out2" 2>/dev/null)" Version 2>/dev/null)"
build v6.2.0 "$WORK/out" >/dev/null 2>&1; check "version with a v is refused" 1 "$?"
build 6.2.0-rc1 "$WORK/out" >/dev/null 2>&1; check "pre-release version is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
