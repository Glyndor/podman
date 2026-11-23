#!/usr/bin/env bash
#
# Tests for scripts/package/build-payload.sh against fake source trees: the three trees come
# out in the places the packages read them from, the versions are read from the sources, the
# toolchain is asked for the hardening the .deb has, and a build whose flags, tags, libraries
# or debug sections are not the ones the package is declared to have is refused. Nothing is
# compiled: make is a Makefile that copies a binary.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/package/build-payload.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/src" "$WORK/nv" "$WORK/aa" "$WORK/fakebin"
mkdir -p "$WORK/mods/common/pkg/config" "$WORK/mods/common/pkg/seccomp" "$WORK/mods/common/rpm" "$WORK/mods/image" "$WORK/mods/storage"
printf 'module x\nrequire (\n\tgo.podman.io/common v0.70.0\n\tgo.podman.io/image/v5 v5.42.1\n\tgo.podman.io/storage v1.65.1\n)\n' > "$WORK/src/go.mod"
for f in common/pkg/config/containers.conf common/rpm/policy.json image/registries.conf image/default.yaml storage/storage.conf; do echo x > "$WORK/mods/$f"; done
echo '{"syscalls":[{"names":["futex_waitv"]}]}' > "$WORK/mods/common/pkg/seccomp/seccomp.json"
echo '[aliases]' > "$WORK/short.conf"
export GLYNDOR_MODULES_DIR="$WORK/mods"
# A binary with a debug section, for the case where strip did nothing.
objcopy --add-section .debug_probe=/etc/hostname /bin/true "$WORK/debug-true" 2> /dev/null
cat > "$WORK/src/Makefile" <<MK
all:
	@echo "\$(EXTRA_BUILDTAGS)" > $WORK/tags; echo "\$\$CGO_CFLAGS" > $WORK/cflags; echo "\$\$CGO_LDFLAGS" > $WORK/ldflags; echo "\$\$GOFLAGS" > $WORK/goflags; echo "\$\$GOTOOLCHAIN" > $WORK/gotoolchain
	rm -f bin/podman; [ -n "\$\$FAKE_NO_BIN" ] || install -D -m755 /bin/true bin/podman
install:
	install -D -m755 \$(if \$(FAKE_DEBUG),$WORK/debug-true,/bin/true) \$(DESTDIR)\$(PREFIX)/bin/podman
	install -D -m755 /bin/true \$(DESTDIR)\$(PREFIX)/bin/podman-remote
	[ -n "\$\$FAKE_NO_LINK" ] || ln -sf podman \$(DESTDIR)\$(PREFIX)/bin/podmansh
	install -D -m644 /dev/null \$(DESTDIR)\$(PREFIX)/share/man/man1/podman-run.1
	install -D -m644 /dev/null \$(DESTDIR)\$(PREFIX)/share/man/man1/podmansh.1
install.completions:
	install -D -m644 /dev/null \$(DESTDIR)\$(PREFIX)/share/bash-completion/completions/podman
docker-docs:
	@echo built >> $WORK/docker-docs.calls
install.docker:
	install -D -m755 /dev/null \$(DESTDIR)\$(PREFIX)/bin/docker
	install -D -m644 /dev/null \$(DESTDIR)\$(ETCDIR)/profile.d/podman-docker.sh
install.docker-docs:
	install -D -m644 /dev/null \$(DESTDIR)\$(PREFIX)/share/man/man1/docker.1
MK
for c in nv aa; do
	touch "$WORK/$c/Cargo.lock"
	printf 'all:\n\t@echo "$(CARGO)" > %s/cargo-%s\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/libexec/podman/%s\n' "$WORK" "$c" "$([ "$c" = nv ] && echo netavark || echo aardvark-dns)" > "$WORK/$c/Makefile"
done
printf '[package]\nname = "netavark"\nversion = "2.1.0"\n' > "$WORK/nv/Cargo.toml"
printf '[package]\nname = "aardvark-dns"\nversion = "2.1.3"\n' > "$WORK/aa/Cargo.toml"
# The Go build info of bin/podman, in the shape `go version -m` has, so a case can take a flag out.
printf '#!/bin/sh\n[ "$1 $2" = "version -m" ] && [ -f "$3" ] && [ -z "$FAKE_GO_FAILS" ] || exit 1\ncat "%s/info"\n' "$WORK" > "$WORK/fakebin/go"
# strip does its work unless told not to; ldd answers what the real one does for a binary that
# links only libc, or a library that should not be there.
printf '#!/bin/sh\n[ -n "$FAKE_NO_STRIP" ] && exit 0\nexec "%s" "$@"\n' "$(command -v strip)" > "$WORK/fakebin/strip"
printf '#!/bin/sh\n[ -z "$FAKE_LDD_FAILS" ] || exit 1\n[ -z "$FAKE_LDD" ] || echo "\t$FAKE_LDD => /usr/lib64/$FAKE_LDD (0x0)"\necho "\tlibc.so.6 => /lib64/libc.so.6 (0x0)"\n' > "$WORK/fakebin/ldd"
chmod +x "$WORK/fakebin/go" "$WORK/fakebin/strip" "$WORK/fakebin/ldd"
full_info="$(printf '\tbuild\t-buildmode=pie\n\tbuild\t-tags=seccomp,selinux,systemd,containers_image_openpgp\n\tbuild\t-trimpath=true\n')"
printf '%s\n' "$full_info" > "$WORK/info"
PATH="$WORK/fakebin:$PATH"
build() { rm -rf "$WORK/payload"; "$SCRIPT" "$WORK/src" "$WORK/nv" "$WORK/aa" "$WORK/payload" "$@" "$WORK/short.conf"; }
# The family comes before the short names: build <family>.
b() { out="$(build "$1" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
P="$WORK/payload"

b fedora
check "a build with everything in place succeeds" 0 "$rc"
check "and prints the payload directory" "$P" "$(printf '%s\n' "$out" | tail -n 1)"
check "podman, podman-remote and the network stack are in the main tree" "usr/bin/podman usr/bin/podman-remote usr/libexec/podman/aardvark-dns usr/libexec/podman/netavark" \
	"$(cd "$P/main" && ls usr/bin/podman usr/bin/podman-remote usr/libexec/podman/aardvark-dns usr/libexec/podman/netavark | paste -sd' ')"
check "the containers-common configuration is in the main tree" "usr/share/containers/seccomp.json" "$(cd "$P/main" && ls usr/share/containers/seccomp.json)"
check "the man pages of the docker shim are made before they are installed" 1 "$(grep -c built "$WORK/docker-docs.calls")"
check "the docker shim and its man page are in the docker tree" "usr/bin/docker usr/share/man/man1/docker.1" "$(cd "$P/docker" && ls usr/bin/docker usr/share/man/man1/docker.1 | paste -sd' ')"
check "podmansh is a link to podman in the sh tree, with its man page" "podman usr/share/man/man1/podmansh.1" \
	"$(readlink "$P/sh/usr/bin/podmansh") $(cd "$P/sh" && ls usr/share/man/man1/podmansh.1)"
check "and neither is left in the main tree" "0" "$(cd "$P/main" && ls usr/bin/podmansh usr/bin/docker usr/share/man/man1/podmansh.1 usr/share/man/man1/docker.1 2> /dev/null | wc -l | tr -d ' ')"
check "facts.env says the versions of the sources" "NETAVARK_VERSION=2.1.0 AARDVARK_VERSION=2.1.3 COMMON_VERSION=0.70.0" "$(paste -sd' ' "$P/facts.env")"
check "gpgme is replaced by Go's OpenPGP" containers_image_openpgp "$(cat "$WORK/tags")"
check "the toolchain of the distribution is the only one: Go downloads none" local "$(cat "$WORK/gotoolchain")"
check "the toolchain is asked for a position independent executable that carries no build path" "-trimpath -buildmode=pie" "$(cat "$WORK/goflags")"
check "the linker is asked for full RELRO and for BIND_NOW" "-Wl,-z,relro -Wl,-z,now" "$(cat "$WORK/ldflags")"
check "the compiler is asked for _FORTIFY_SOURCE=2" 1 "$(grep -c -w -e '-D_FORTIFY_SOURCE=2' "$WORK/cflags")"
check "and, on this machine, for the control-flow protection of its architecture" 1 "$(grep -c -e '-fcf-protection=full' -e '-mbranch-protection=standard' "$WORK/cflags")"
check "cargo builds only what the lockfile of the tag says" "cargo --locked" "$(cat "$WORK/cargo-nv")"

for family in el amzn suse arch; do
	b "$family"; check "the family $family is built" 0 "$rc"
done
b gentoo; check "an unknown family is a usage error" "2 1" "$rc $(says 'unknown family: gentoo')"

# --- a binary that lacks what was asked for ------------------------------------------------
for want in selinux seccomp systemd; do
	printf '%s\n' "$full_info" | grep -v -- "-tags=" > "$WORK/info"
	printf '\tbuild\t-buildmode=pie\n\tbuild\t-trimpath=true\n\tbuild\t-tags=%s\n' "$(echo seccomp,selinux,systemd | tr ',' '\n' | grep -v -x "$want" | paste -sd,)" >> "$WORK/info"
	b fedora; check "a binary without the $want tag is refused" "1 1" "$rc $(says "the built podman lacks $want")"
done
printf '\tbuild\t-buildmode=pie\n\tbuild\t-tags=seccomp,systemd\n\tbuild\t-trimpath=true\n' > "$WORK/info"
b arch; check "Arch has no SELinux and the tag is not asked of it" 0 "$rc"
for flag in -trimpath=true -buildmode=pie; do
	printf '%s\n' "$full_info" | grep -v -e "$flag" > "$WORK/info"
	b fedora; check "a binary without $flag is refused" "1 1" "$rc $(says "the built podman lacks $flag")"
done
printf '%s\n' "$full_info" > "$WORK/info"
FAKE_NO_BIN=1 b fedora; check "a make that leaves no binary is refused" "1 1" "$rc $(says 'make left no bin/podman to check')"
FAKE_GO_FAILS=1 b fedora; check "a build whose info cannot be read is refused" "1 1" "$rc $(says 'cannot read the build info of bin/podman')"
# A PATH with the tools the script needs and no go, whatever else the machine has installed.
mkdir "$WORK/nogo"
for tool in bash env make install ln rm mkdir cp mv find sort xargs file readelf awk grep sed mktemp uname date git dirname cat head tr; do
	[ -z "$(command -v "$tool")" ] || ln -s "$(command -v "$tool")" "$WORK/nogo/$tool"
done
for tool in strip ldd; do ln -s "$WORK/fakebin/$tool" "$WORK/nogo/$tool"; done
out="$(PATH="$WORK/nogo" "$SCRIPT" "$WORK/src" "$WORK/nv" "$WORK/aa" "$WORK/payload" fedora "$WORK/short.conf" 2>&1)"; rc=$?
check "no go to read the build info with is refused" "1 1" "$rc $(says 'no go to read the build info')"

# --- what the package must not be linked to or carry -------------------------------------
FAKE_LDD=libgpgme.so.45 b fedora; check "a binary linked to gpgme is refused" "1 1" "$rc $(says 'build links a library the package is not meant to depend on')"
FAKE_LDD=libsqlite3.so.0 b fedora; check "so is sqlite" "1 1" "$rc $(says 'build links a library')"
FAKE_LDD=libsubid.so.6 b fedora; check "so is subid" "1 1" "$rc $(says 'build links a library')"
FAKE_LDD_FAILS=1 b fedora; check "libraries that cannot be read are refused" "1 1" "$rc $(says 'could not read the libraries the binaries link against')"
FAKE_NO_LINK=1 b fedora; check "a make install that leaves no podmansh link is refused" "1 1" "$rc $(says 'make install left no podmansh link')"
FAKE_DEBUG=1 FAKE_NO_STRIP=1 b fedora; check "a binary that still has debug sections is refused" "1 1" "$rc $(says 'still has debug sections')"
FAKE_DEBUG=1 b fedora; check "and strip removes them when it runs" "0" "$rc"

# --- the sources ----------------------------------------------------------------------------
rm "$WORK/nv/Cargo.lock"; b fedora; check "a source tree with no Cargo.lock is refused" "1 1" "$rc $(says 'has no Cargo.lock to build against')"; touch "$WORK/nv/Cargo.lock"
printf '[package]\nname = "netavark"\nversion = "two"\n' > "$WORK/nv/Cargo.toml"
b fedora; check "a crate version that is not one is refused" "1 1" "$rc $(says 'cannot read the netavark or aardvark-dns version')"
printf '[package]\nname = "netavark"\nversion = "2.1.0"\n' > "$WORK/nv/Cargo.toml"
printf 'module x\nrequire (\n\tgo.podman.io/common vX\n)\n' > "$WORK/src/go.mod"
b fedora; check "a Podman whose go.mod names no containers-common is refused" "1" "$rc"
printf 'module x\nrequire (\n\tgo.podman.io/common v0.70.0\n\tgo.podman.io/image/v5 v5.42.1\n)\n' > "$WORK/src/go.mod"
rm "$WORK/mods/common/pkg/seccomp/seccomp.json"; b fedora; check "a release without a seccomp profile is refused" "1" "$rc"
echo '{}' > "$WORK/mods/common/pkg/seccomp/seccomp.json"
: > "$WORK/short.conf"; b fedora; check "an empty short-name list is refused" "1" "$rc"
rm -rf "$WORK/payload"; "$SCRIPT" "$WORK/src" "$WORK/nv" "$WORK/aa" "$WORK/payload" fedora > /dev/null 2>&1; check "no short-name list at all is a usage error" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
