#!/usr/bin/env bash
#
# Tests for scripts/build/build-deb.sh against a fake source tree: the .deb must
# be named for the package and version, a malformed version is refused, and so is
# a build whose flags or glibc floor cannot be read.
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
# passt's own install copies doc/demo.sh with its executable bit: a script among the binaries.
printf 'all:\n\t@echo "$$CFLAGS" > %s/passt-cflags\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(prefix)/bin/passt\n\tinstall -D -m755 demo.sh $(DESTDIR)$(prefix)/share/doc/passt/demo.sh\n' "$WORK" > "$WORK/passt/Makefile"
printf '#!/bin/sh\nexit 0\n' > "$WORK/passt/demo.sh"
echo p > "$WORK/passt/contrib/apparmor/usr.bin.passt"; echo p > "$WORK/passt/contrib/apparmor/abstractions/passt"
# pasta's profile in the shape upstream ships it: the profile holds one include of the abstraction
# and then its own rules. The abstraction is a bare list of rules, with no profile around it.
printf '%s\n' 'abi <abi/4.0>,' '' 'include <tunables/global>' '' \
	'profile pasta /usr/bin/pasta{,.avx2} flags=(attach_disconnected) {' '  include <abstractions/pasta>' '' \
	'  /tmp/**                          rw,' '  owner @{HOME}/**                  w,' '}' > "$WORK/passt/contrib/apparmor/usr.bin.pasta"
printf '%s\n' 'abi <abi/4.0>,' '' '  include <abstractions/passt>' '' '  ptrace r,' > "$WORK/passt/contrib/apparmor/abstractions/pasta"
mkdir -p "$WORK/mods/common/pkg/config" "$WORK/mods/common/pkg/seccomp" "$WORK/mods/common/rpm" "$WORK/mods/image" "$WORK/mods/storage"
printf 'module x\nrequire (\n\tgo.podman.io/common v0.70.0\n\tgo.podman.io/image/v5 v5.42.1\n\tgo.podman.io/storage v1.65.1\n)\n' > "$WORK/src/go.mod"
for f in common/pkg/config/containers.conf common/rpm/policy.json image/registries.conf image/default.yaml storage/storage.conf; do echo x > "$WORK/mods/$f"; done
echo '{"syscalls":[{"names":["futex_waitv"]}]}' > "$WORK/mods/common/pkg/seccomp/seccomp.json"
echo '[aliases]' > "$WORK/short.conf"
export GLYNDOR_PASST_SRC="$WORK/passt" GLYNDOR_MODULES_DIR="$WORK/mods" GLYNDOR_SHORTNAMES="$WORK/short.conf"
printf 'all:\n\t@echo "$(EXTRA_BUILDTAGS)" > %s/tags; echo "$$CGO_CFLAGS" > %s/cflags; echo "$$CGO_LDFLAGS" > %s/ldflags; echo "$$GOFLAGS" > %s/goflags\n\trm -f bin/podman; [ -n "$$FAKE_NO_BIN" ] || install -D -m755 /bin/true bin/podman\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/bin/podman\ninstall.completions:\n\tinstall -D -m644 /dev/null $(DESTDIR)$(PREFIX)/share/bash-completion/completions/podman\n' "$WORK" "$WORK" "$WORK" "$WORK" > "$WORK/src/Makefile"
printf 'all:\n\t@echo "$(CARGO)" > %s/cargo-nv\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/libexec/podman/netavark\n' "$WORK" > "$WORK/nv/Makefile"; touch "$WORK/nv/Cargo.lock" "$WORK/aa/Cargo.lock"
printf '[package]\nname = "netavark"\nversion = "2.1.0"\n' > "$WORK/nv/Cargo.toml"
printf '[package]\nname = "aardvark-dns"\nversion = "2.1.3"\n' > "$WORK/aa/Cargo.toml"
printf 'all:\n\t@true\ninstall:\n\tinstall -D -m755 /bin/true $(DESTDIR)$(PREFIX)/libexec/podman/aardvark-dns\n' > "$WORK/aa/Makefile"
# The build reads the Go build info of bin/podman. This go prints $WORK/info, in the
# shape `go version -m` has, so a case can take one flag out of it.
mkdir "$WORK/fakebin"
printf '#!/bin/sh\n[ "$1 $2" = "version -m" ] && [ -f "$3" ] && [ -z "$FAKE_GO_FAILS" ] || exit 1\ncat "%s/info"\n' "$WORK" > "$WORK/fakebin/go"
chmod +x "$WORK/fakebin/go"
# What the build hands to the tools that decide how the package is made. dpkg-buildflags
# answers a hardened CFLAGS only when asked for hardening=+all, as the real one does with
# more flags; dpkg-deb and strip record how they were called and then do their work.
cat > "$WORK/fakebin/dpkg-buildflags" <<'BUILDFLAGS'
#!/bin/sh
[ "$1" = --export=sh ] || exit 2
case "$DEB_BUILD_MAINT_OPTIONS" in
	hardening=+all) echo 'export CFLAGS="-hardened"' ;;
	*) echo 'export CFLAGS="-not-hardened"' ;;
esac
BUILDFLAGS
for tool in dpkg-deb strip; do
	printf '#!/bin/sh\necho "$*" >> "%s/%s.calls"\nexec "%s" "$@"\n' "$WORK" "$tool" "$(command -v "$tool")" > "$WORK/fakebin/$tool"
done
# apparmor_parser compiles the profile of pasta and loads nothing. This one records how it was
# called and the profile it was given, as it was when called, and fails when told to.
cat > "$WORK/fakebin/apparmor_parser" <<'PARSER'
#!/bin/sh
echo "$*" >> "$AA_CALLS"
for last; do :; done
cp "$last" "$AA_PROFILE"
[ -z "$FAKE_AA_FAILS" ] || { echo "AppArmor parser error: syntax error" >&2; exit 1; }
PARSER
printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/aa-enabled"; chmod +x "$WORK/fakebin/aa-enabled"
export AA_CALLS="$WORK/aa.calls" AA_PROFILE="$WORK/aa.profile"
chmod +x "$WORK/fakebin/dpkg-buildflags" "$WORK/fakebin/dpkg-deb" "$WORK/fakebin/strip" "$WORK/fakebin/apparmor_parser"
full_info="$(printf '\tbuild\t-buildmode=pie\n\tbuild\t-tags=apparmor,seccomp,selinux,systemd,containers_image_openpgp\n\tbuild\t-trimpath=true\n')"
printf '%s\n' "$full_info" > "$WORK/info"
PATH="$WORK/fakebin:$PATH"
build() { "$SCRIPT" "$WORK/src" "$WORK/nv" "$WORK/aa" "$@"; }
arch="$(dpkg --print-architecture)"

deb="$(build 6.2.0 "$WORK/out" 2>/dev/null)"
# What the build gave make and passt, read now: later builds in this file write them again.
snap() { cflags="$(cat "$WORK/cflags" 2>/dev/null)"; ldflags="$(cat "$WORK/ldflags" 2>/dev/null)"
	goflags="$(cat "$WORK/goflags" 2>/dev/null)"; passt_cflags="$(cat "$WORK/passt-cflags" 2>/dev/null)"; }
snap
build_calls="$(grep -- '--build' "$WORK/dpkg-deb.calls" 2>/dev/null)"; strip_calls="$(cat "$WORK/strip.calls" 2>/dev/null)"
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
check "policy.json is shipped under /usr/share/containers, like the rest of the configuration" ./usr/share/containers/policy.json \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x './usr/share/containers/policy.json')"
check "and nothing is shipped under /etc/containers but the empty directories: no file of the administrator's is the package's" 0 \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '$1 ~ /^-/ {print $6}' | grep -c '^./etc/containers/')"
check "so nothing is a conffile and dpkg never asks about one" 0 "$(dpkg-deb -e "$deb" "$WORK/ctl" 2>/dev/null; [ -e "$WORK/ctl/conffiles" ] && echo 1 || echo 0)"

# --- the maintainer scripts that keep an edited policy.json across the upgrade from a release that shipped it ---
# Run against a root of their own (DPKG_ROOT), with the real dpkg --compare-versions.
ctl="$WORK/ctl"
mkdir -p "$ctl"; dpkg-deb -e "$deb" "$ctl"
EMPTY=d41d8cd98f00b204e9800998ecf8427e
upgrade_case() { # <old version, "" for a first install> <setup: unedited-r11|unedited-empty|edited|absent|link|dangling> -> prints what is left (a link: where it points)
	local root="$WORK/root"; rm -rf "$root"; mkdir -p "$root/etc/containers" "$root/usr/share/containers"
	printf '%s\n' "$DEFAULT_NEW" > "$root/usr/share/containers/policy.json"
	case "$2" in
		unedited-r11) cp "$HERE/tests/build/fixtures/policy.json.r7-to-r11" "$root/etc/containers/policy.json" ;;
		unedited-empty) : > "$root/etc/containers/policy.json" ;;
		edited) printf '{"default":[{"type":"reject"}]}\n' > "$root/etc/containers/policy.json" ;;
		link) printf '{"default":[{"type":"reject"}]}\n' > "$root/central.json"; ln -s "$root/central.json" "$root/etc/containers/policy.json" ;;
		dangling) ln -s /nonexistent "$root/etc/containers/policy.json" ;;
		absent) ;;
	esac
	if [ -n "$1" ]; then
		DPKG_ROOT="$root" sh "$ctl/preinst" upgrade "$1" > "$WORK/pre.out" 2>&1; pre_rc=$?
		# dpkg removes what the old package had and the new one does not list, a link in its place as well
		rm -f "$root/etc/containers/policy.json"
		DPKG_ROOT="$root" sh "$ctl/postinst" configure "$1" > "$WORK/post.out" 2>&1; post_rc=$?
	else
		pre_rc=0; DPKG_ROOT="$root" sh "$ctl/postinst" configure > "$WORK/post.out" 2>&1; post_rc=$?
	fi
	if [ -L "$root/etc/containers/policy.json" ]; then left="link:$(readlink "$root/etc/containers/policy.json")"
	else left="$(cat "$root/etc/containers/policy.json" 2>/dev/null | tr -d '\n')"; fi
	kept="$([ -e "$root/etc/containers/policy.json.glyndor-kept" ] || [ -L "$root/etc/containers/policy.json.glyndor-kept" ] && echo kept-file-left)"
	echo "$pre_rc$post_rc|$left|$kept"
}
DEFAULT_NEW='{"default":[{"type":"insecureAcceptAnything"},{"new":"default"}]}'
want_new="$(printf '%s' "$DEFAULT_NEW")"
check "the scripts know the sums of the policy.json that releases shipped, the empty one and the default of r7 to r11" "$EMPTY ff61005e84c18498ed1b9d3f1b48db0a" \
	"$(grep -o 'case " [0-9a-f ]* " in' "$ctl/preinst" | head -n 1 | sed 's/case " //; s/ " in//')"
check "a first install with no file in /etc: the default is copied there" "00|$want_new|" "$(upgrade_case "" absent)"
check "a first install where the administrator already put one: it is not touched" "00|{\"default\":[{\"type\":\"reject\"}]}|" "$(upgrade_case "" edited)"
check "from r11, edited: the edited file is back, nothing is left beside it" "00|{\"default\":[{\"type\":\"reject\"}]}|" "$(upgrade_case 6.2.0+r11 edited)"
check "from r11, unedited (the file of releases r7 to r11 as published): the new default replaces it and nothing is kept beside" "00|$want_new|" "$(upgrade_case 6.2.0+r11 unedited-r11)"
check "from r11, the file of the empty default (r2 to r6): the new default replaces it" "00|$want_new|" "$(upgrade_case 6.2.0+r4 unedited-empty)"
check "from r11, deleted by the administrator: the default is copied, once, so buildah and skopeo have a policy" "00|$want_new|" "$(upgrade_case 6.2.0+r11 absent)"
check "from a release that already is this one, nothing is done: an edited file is whatever dpkg left, and an absent one stays absent" "00||" "$(upgrade_case 6.2.0+r12 absent)"
check "from r11, a link to the administrator's policy: the link is back and points where it did, nothing is left beside it" "00|link:$WORK/root/central.json|" "$(upgrade_case 6.2.0+r11 link)"
check "and the file it points to is untouched" '{"default":[{"type":"reject"}]}' "$(tr -d '\n' < "$WORK/root/central.json")"
check "from r11, a link that points nowhere is kept as it was, and the default is not copied over it" "00|link:/nonexistent|" "$(upgrade_case 6.2.0+r11 dangling)"
# --- what a purge takes away, and what an interrupted upgrade leaves ----------------------------------------
# postrm purge removes /etc/containers/policy.json when postinst made it and nobody changed it, and only then.
root="$WORK/root"
state() { # what is left of the policy, its record and the directory, after the steps run on $root
	echo "$([ -e "$root/etc/containers/policy.json" ] && echo file || echo nofile)|$([ -e "$root/var/lib/glyndor-podman/policy.md5" ] && echo record || echo norecord)|$([ -d "$root/etc/containers" ] && echo dir || echo nodir)|$(find "$root/etc/containers" -name "*glyndor*" 2> /dev/null | wc -l)"
}
purge() { DPKG_ROOT="$root" sh "$ctl/postrm" purge > "$WORK/purge.out" 2>&1; echo "$?"; }
upgrade_case "" absent > /dev/null
check "a first install makes the file and records its sum" "file|record|dir|0" "$(state)"
check "a removal that is not a purge touches nothing" "0 file|record|dir|0" "$(DPKG_ROOT="$root" sh "$ctl/postrm" remove > /dev/null 2>&1; echo "$? $(state)")"
check "a purge takes away the copy that was never changed, with its record and the directory it made empty" "0 nofile|norecord|nodir|0" "$(echo "$(purge) $(state)")"
upgrade_case "" absent > /dev/null; printf '{"default":[{"type":"reject"}]}\n' > "$root/etc/containers/policy.json"
check "a purge of a file the administrator edited after the copy keeps it, and still takes the record" "0 file|norecord|dir|0" "$(echo "$(purge) $(state)")"
upgrade_case "" edited > /dev/null
check "a file the administrator made before the first install has no record, and a purge keeps it" "0 file|norecord|dir|0" "$(echo "$(purge) $(state)")"
upgrade_case 6.2.0+r11 edited > /dev/null
check "an edited file put back by an upgrade has no record, and a purge keeps it" "0 file|norecord|dir|0" "$(echo "$(purge) $(state)")"
upgrade_case 6.2.0+r11 unedited-r11 > /dev/null
check "the default that an upgrade from r11 copied is recorded, and a purge takes it" "0 nofile|norecord|nodir|0" "$(echo "$(purge) $(state)")"
# the copy that r12 made had no record: the configuration of this release adopts it when it is the default, and only then
upgrade_case "" absent > /dev/null; rm -rf "$root/var/lib/glyndor-podman"
DPKG_ROOT="$root" sh "$ctl/postinst" configure 6.2.0+r12 > /dev/null 2>&1
check "a copy made by r12, with no record, is adopted when it is the default of the package, and a purge takes it" "record 0 nofile|norecord|nodir|0" \
	"$(echo "$(state | cut -d'|' -f2) $(purge) $(state)")"
upgrade_case "" edited > /dev/null; DPKG_ROOT="$root" sh "$ctl/postinst" configure 6.2.0+r12 > /dev/null 2>&1
check "a file of the administrator's that differs from the default is not adopted by the configuration of a later release" "norecord" "$(state | cut -d'|' -f2)"
# postrm does nothing and does not fail when it is not a purge, or when there is nothing of the package's to take
for action in remove upgrade disappear failed-upgrade abort-install abort-upgrade; do
	upgrade_case "" absent > /dev/null
	check "postrm $action exits 0 and leaves the file and its record" "0 file|record|dir|0" "$(DPKG_ROOT="$root" sh "$ctl/postrm" "$action" > /dev/null 2>&1; echo "$? $(state)")"
done
rm -rf "$root/var/lib/glyndor-podman"
check "postrm purge with no /var/lib/glyndor-podman exits 0 and keeps a file that has no record" "0 file|norecord|dir|0" "$(echo "$(purge) $(state)")"
rm -rf "$root"; mkdir -p "$root"
check "postrm purge with nothing of the package on the machine exits 0" "0" "$(purge)"
check "and a second purge exits 0 as well" "0" "$(purge)"
# an upgrade that stops between preinst and postinst leaves the kept file; the next configuration is the one that puts it back
interrupted() { # <what the administrator does in /etc before the next configuration: nothing|other|same>
	rm -rf "$root"; mkdir -p "$root/etc/containers" "$root/usr/share/containers"; printf '%s\n' "$DEFAULT_NEW" > "$root/usr/share/containers/policy.json"
	printf '{"default":[{"type":"reject"}]}\n' > "$root/etc/containers/policy.json"
	DPKG_ROOT="$root" sh "$ctl/preinst" upgrade 6.2.0+r11 > /dev/null 2>&1; rm -f "$root/etc/containers/policy.json"
	case "$1" in other) printf '{"default":[{"type":"reject"},{"x":1}]}\n' > "$root/etc/containers/policy.json" ;; same) printf '{"default":[{"type":"reject"}]}\n' > "$root/etc/containers/policy.json" ;; esac
	DPKG_ROOT="$root" sh "$ctl/postinst" configure 6.2.0+r11 > "$WORK/post.out" 2>&1
	echo "$(tr -d '\n' < "$root/etc/containers/policy.json" 2> /dev/null)|$(find "$root/etc/containers" -name "*.glyndor-kept" | wc -l)|$(find "$root/etc/containers" -name "*.glyndor-previous" | wc -l)|$(grep -c 'interrupted' "$WORK/post.out")"
}
check "an interrupted upgrade: the next configuration puts the administrator's file back, and the kept copy is gone" "{\"default\":[{\"type\":\"reject\"}]}|0|0|0" "$(interrupted nothing)"
check "an interrupted upgrade and a file the administrator made in the meantime: that file stays, the earlier one is kept under another name, and it is said" "{\"default\":[{\"type\":\"reject\"},{\"x\":1}]}|0|1|1" "$(interrupted other)"
check "an interrupted upgrade and the same file made again: the kept copy is dropped, nothing is lost" "{\"default\":[{\"type\":\"reject\"}]}|0|0|0" "$(interrupted same)"
# the same with a link: the kept copy is the link itself, whatever it points at
linked() { # <what the administrator does in /etc before the next configuration: nothing|same|other>
	rm -rf "$root"; mkdir -p "$root/etc/containers" "$root/usr/share/containers"; printf '%s\n' "$DEFAULT_NEW" > "$root/usr/share/containers/policy.json"
	ln -s /srv/central.json "$root/etc/containers/policy.json"
	DPKG_ROOT="$root" sh "$ctl/preinst" upgrade 6.2.0+r11 > /dev/null 2>&1; rm -f "$root/etc/containers/policy.json"
	case "$1" in same) ln -s /srv/central.json "$root/etc/containers/policy.json" ;; other) ln -s /srv/other.json "$root/etc/containers/policy.json" ;; esac
	DPKG_ROOT="$root" sh "$ctl/postinst" configure 6.2.0+r11 > "$WORK/post.out" 2>&1
	echo "$(readlink "$root/etc/containers/policy.json" || echo none)|$(find "$root/etc/containers" -name "*.glyndor-kept" | wc -l)|$(readlink "$root/etc/containers/policy.json.glyndor-previous" || echo none)"
}
check "an interrupted upgrade with a link: the next configuration puts the link back" "/srv/central.json|0|none" "$(linked nothing)"
check "an interrupted upgrade and the same link made again: the kept link is dropped" "/srv/central.json|0|none" "$(linked same)"
check "an interrupted upgrade and another link made in the meantime: that one stays, the earlier one is kept under another name" "/srv/other.json|0|/srv/central.json" "$(linked other)"
for f in ./usr/bin/passt ./usr/bin/pasta ./etc/apparmor.d/usr.bin.passt ./etc/apparmor.d/abstractions/passt \
	./etc/apparmor.d/usr.bin.pasta ./etc/apparmor.d/abstractions/pasta; do
	check "passt ships $f" "$f" "$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x "$f")"
done
check "an executable script in the tree does not stop the build" ./usr/share/doc/passt/demo.sh \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $6}' | grep -x './usr/share/doc/passt/demo.sh')"
check "passt is no longer only recommended" 0 "$(dpkg-deb -f "$deb" Recommends 2>/dev/null | grep -c passt)"
check "the AppArmor profiles are loaded on configure" 1 "$(dpkg-deb -I "$deb" postinst 2>/dev/null | grep -c 'apparmor_parser -r')"
check "the distribution's containers-common is not depended on" 0 "$(dpkg-deb -f "$deb" Depends 2>/dev/null | grep -c 'golang-github-containers-common')"
check "an old crun is removed rather than left to fail" "crun (<< 1.21)" "$(dpkg-deb -f "$deb" Breaks 2>/dev/null)"
check "catatonit is required, as upstream does" 1 "$(dpkg-deb -f "$deb" Depends 2>/dev/null | grep -c 'catatonit')"
rm "$WORK/mods/common/pkg/seccomp/seccomp.json"
build 6.2.0 "$WORK/out2" >/dev/null 2>&1; rc=$?; check "a release without a seccomp profile is refused" 1 "$rc"
echo '{}' > "$WORK/mods/common/pkg/seccomp/seccomp.json"

# --- the hardening the package is declared to have ------------------------------------------
# The build checks the build info of the binary for -trimpath and -buildmode=pie and nothing
# else, so the rest is what it asks of the compiler and the linker: that is what these read,
# in the variables make receives, and none of it is a refusal for the mutation check to see.
# The real binary is not inspected here, since nothing is compiled.
check "the toolchain is asked for a position independent executable that carries no build path" "-trimpath -buildmode=pie" "$goflags"
check "the linker is asked for full RELRO and for BIND_NOW" "-Wl,-z,relro -Wl,-z,now" "$ldflags"
check "the compiler is asked for _FORTIFY_SOURCE=2" 1 "$(printf '%s\n' "$cflags" | grep -c -w -e '-D_FORTIFY_SOURCE=2')"
check "passt is built with the flags dpkg-buildflags gives for hardening=+all" "-hardened" "$passt_cflags"
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

# The build info check refuses rather than skips. Each case is a build that is
# fine in every other respect, and asserts the refusal it expects.
refused() { # <out-dir>: sets $rc to the exit code and $err to what it printed on stderr
	rc=0; build 6.2.0 "$1" >/dev/null 2>"$WORK/err" || rc=$?
	err="$(cat "$WORK/err")"
}
# Control-flow protection is spelled differently per architecture and the suite runs on one,
# so dpkg is made to say which it is: a runner of the other kind would never reach the branch.
fakearch="$WORK/fakearch"; mkdir "$fakearch"
printf '#!/bin/sh\n[ "$1" = --print-architecture ] && [ -n "$FAKE_ARCH" ] && { echo "$FAKE_ARCH"; exit 0; }\nexec "%s" "$@"\n' "$(command -v dpkg)" > "$fakearch/dpkg"
chmod +x "$fakearch/dpkg"
for pair in "amd64:-fcf-protection=full" "arm64:-mbranch-protection=standard" "riscv64:"; do
	flag_arch="${pair%%:*}"; flag="${pair#*:}"
	rm -f "$WORK/cflags"
	FAKE_ARCH="$flag_arch" PATH="$fakearch:$PATH" refused "$WORK/out-$flag_arch"
	snap
	check "$flag_arch builds, and the package says so" "0 $flag_arch" "$rc $(dpkg-deb -f "$WORK/out-$flag_arch/podman_6.2.0_$flag_arch.deb" Architecture 2>/dev/null)"
	check "$flag_arch gets ${flag:-no control-flow flag} and nothing of the other architecture's" "-O2 -g ${flag:+$flag }-D_FORTIFY_SOURCE=2" "$(printf '%s' "$cflags" | tr -s ' ')"
done

# --- the package is made the way it says ------------------------------------------------------
check "the package is built with --root-owner-group, by one call to dpkg-deb --build" "1 1" \
	"$(printf '%s\n' "$build_calls" | grep -c -- '--build') $(printf '%s\n' "$build_calls" | grep -c -- '--root-owner-group')"
check "and every file in it belongs to root, whoever built it" "root/root" "$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $2}' | sort -u)"
check "the binaries are stripped of what they do not need, not only of debug sections" 1 \
	"$(printf '%s\n' "$strip_calls" | grep -c -- '--strip-unneeded')"
for flag in -trimpath=true -buildmode=pie apparmor seccomp systemd; do
	printf '%s\n' "$full_info" | sed "s/$flag//" > "$WORK/info"
	refused "$WORK/out-$flag"
	check "a podman built without $flag is refused" "1 1" "$rc $(printf '%s' "$err" | grep -c -- "the built podman lacks $flag")"
done
printf '%s\n' "$full_info" > "$WORK/info"

# No go on the PATH at all: every other command the build runs, linked. Linking one file at a
# time over every directory of the PATH took five seconds; one call of ln per directory, from the
# last directory to the first so that the first one wins a name as it does on a PATH, takes a tenth.
mkdir "$WORK/nogo"
IFS=: read -r -a dirs <<< "$PATH"
for ((i = ${#dirs[@]} - 1; i >= 0; i--)); do
	[ ! -d "${dirs[i]}" ] || ln -sf "${dirs[i]}"/* "$WORK/nogo/" 2>/dev/null
done
rm -f "$WORK/nogo/go"
PATH="$WORK/nogo" refused "$WORK/out-nogo"
check "a build with no go to read the build info is refused" "1 1" "$rc $(printf '%s' "$err" | grep -c 'no go to read the build info')"
FAKE_GO_FAILS=1 refused "$WORK/out-gofails"
check "a build info that cannot be read is refused" "1 1" "$rc $(printf '%s' "$err" | grep -c 'cannot read the build info')"
FAKE_NO_BIN=1 refused "$WORK/out-nobin"
check "a make that leaves no bin/podman is refused" "1 1" "$rc $(printf '%s' "$err" | grep -c 'left no bin/podman')"

# The inputs the build reads before it compiles anything, each refused by name.
rm "$WORK/nv/Cargo.lock"
refused "$WORK/out-nolock"
check "a Rust source with no Cargo.lock to build against is refused" "1 1" "$rc $(printf '%s' "$err" | grep -c "$WORK/nv has no Cargo.lock to build against")"
touch "$WORK/nv/Cargo.lock"
GLYNDOR_PASST_SRC="$WORK/no-passt" refused "$WORK/out-nopasst"
check "a passt source that is not there is refused" "1 1" "$rc $(printf '%s' "$err" | grep -c "no passt source at $WORK/no-passt")"
cp "$WORK/aa/Cargo.toml" "$WORK/aa/Cargo.toml.real"
printf '[package]\nname = "aardvark-dns"\nversion = "2.1"\n' > "$WORK/aa/Cargo.toml"
refused "$WORK/out-noversion"
check "a crate version that is not X.Y.Z is refused, and no package is written" "1 1 0" \
	"$rc $(printf '%s' "$err" | grep -c 'cannot read the netavark or aardvark-dns version from Cargo.toml') $(find "$WORK/out-noversion" -name '*.deb' 2>/dev/null | wc -l)"
mv "$WORK/aa/Cargo.toml.real" "$WORK/aa/Cargo.toml"

# The glibc floor is read from the binaries or the build stops: a fallback would
# declare libc6 (>= 2.0) and the package would install where it cannot run.
mkdir "$WORK/objdump-fails" "$WORK/objdump-empty"
printf '#!/bin/sh\necho "0000000000000000      DF *UND*  0000000000000000 (GLIBC_2.34) __libc_start_main"\nexit 1\n' > "$WORK/objdump-fails/objdump"
printf '#!/bin/sh\nexit 0\n' > "$WORK/objdump-empty/objdump"
chmod +x "$WORK/objdump-fails/objdump" "$WORK/objdump-empty/objdump"
PATH="$WORK/objdump-fails:$PATH" refused "$WORK/out-objdump-fails"
check "an objdump that fails is refused, even after printing a version" "1 1" "$rc $(printf '%s' "$err" | grep -c 'could not read the glibc symbols')"
PATH="$WORK/objdump-empty:$PATH" refused "$WORK/out-objdump-empty"
check "binaries that show no glibc symbol are refused" "1 1" "$rc $(printf '%s' "$err" | grep -c 'could not read the glibc symbols')"

# Release artifacts ship stripped. strip runs on every ELF, and a binary that still
# has a debug section afterwards stops the build: the fixtures here have none, so a
# readelf that reports one for a single file stands in for a strip that did nothing.
mkdir "$WORK/debug-left"
real_readelf="$(command -v readelf)"
cat > "$WORK/debug-left/readelf" <<READELF
#!/bin/sh
if [ "\$1" = -S ] && [ "\${2##*/}" = netavark ]; then
	printf '  [27] .debug_info       PROGBITS         0000000000000000  000a1b2c\n'
	exit 0
fi
exec "$real_readelf" "\$@"
READELF
chmod +x "$WORK/debug-left/readelf"
PATH="$WORK/debug-left:$PATH" refused "$WORK/out-debug-left"
check "a binary that keeps a debug section after strip is refused, and named" "1 1" \
	"$rc $(printf '%s' "$err" | grep -c -- '/usr/libexec/podman/netavark still has debug sections')"
check "and no package is written" 0 "$(find "$WORK/out-debug-left" -name '*.deb' 2>/dev/null | wc -l)"

# One package has to serve Debian 13 and Ubuntu 24.04 and 26.04, so a build that links
# a library renamed between them is refused, and the libraries it may link are the ones
# that stay. ldd names what the binaries link, and dpkg -S the package that owns each
# file: both are faked, so the case does not depend on what this machine has installed.
# The accepted shape comes first, so a refusal below is for the library and not for a
# harness that cannot build.
mkdir "$WORK/fakeldd" "$WORK/libs"
real_dpkg="$(command -v dpkg)"
cat > "$WORK/fakeldd/ldd" <<'LDD'
#!/bin/sh
for lib in $FAKE_LIBS; do
	printf '\t%s.so.1 => %s/%s (0x00007f0000000000)\n' "$lib" "$LIBS_DIR" "$lib"
done
LDD
cat > "$WORK/fakeldd/dpkg" <<DPKG
#!/bin/sh
[ "\$1" = -S ] || exec "$real_dpkg" "\$@"
shift
for f in "\$@"; do printf '%s:%s: %s\\n' "\${f##*/}" amd64 "\$f"; done
DPKG
chmod +x "$WORK/fakeldd/ldd" "$WORK/fakeldd/dpkg"
links() { # <libraries...>: a build whose binaries link these, as the package names that own them
	local lib
	for lib in "$@"; do : > "$WORK/libs/$lib"; done
	last_out="$WORK/out-links-$RANDOM"
	FAKE_LIBS="$*" LIBS_DIR="$WORK/libs" PATH="$WORK/fakeldd:$PATH" refused "$last_out"
}
links libc6 libgcc-s1 libseccomp2
check "a build that links only libc, libgcc and libseccomp is accepted" 0 "$rc"
deb="$(ls "$last_out"/podman_6.2.0_*.deb 2>/dev/null)"
check "and it depends on exactly those three, libc6 with the glibc floor" "libc6 (>= N), libgcc-s1, libseccomp2" \
	"$(dpkg-deb -f "$deb" Depends 2>/dev/null | sed 's/.*nftables, //; s/(>= [0-9.]*)/(>= N)/')"
for lib in libgpgme11t64 libassuan9 libsubid5 libsqlite3-0 libapparmor1 libbtrfs0t64; do
	links libc6 "$lib"
	check "a build that also links $lib is refused" "1 1" "$rc $(printf '%s' "$err" | grep -c -- "^build links a library that differs between releases: .*\\<$lib\\>")"
	check "and no package is written for $lib" 0 "$(find "$last_out" -name '*.deb' 2>/dev/null | wc -l)"
done

# What the build reads from passt and from ldd has to be there: each refusal is by name, and writes no package.
cp -r "$WORK/passt" "$WORK/passt-bad"
printf 'all:\n\t@true\ninstall:\n\t@true\n' > "$WORK/passt-bad/Makefile"
GLYNDOR_PASST_SRC="$WORK/passt-bad" refused "$WORK/out-nopasstbin"
check "a passt that installs no usr/bin/passt is refused, and says so, not just a failed link" "1 1 0" \
	"$rc $(printf '%s' "$err" | grep -c 'passt did not install an executable usr/bin/passt\|ln: failed to access') $(find "$WORK/out-nopasstbin" -name '*.deb' 2>/dev/null | wc -l)"
mkdir "$WORK/fakeparse"; printf '#!/bin/sh\nexit 0\n' > "$WORK/fakeparse/dpkg-parsechangelog"; chmod +x "$WORK/fakeparse/dpkg-parsechangelog"
PATH="$WORK/fakeparse:$PATH" refused "$WORK/out-nopasstversion"
check "a changelog that gives no version is refused with a message, and no Provides: passt (= ) is written" "1 1 0" \
	"$rc $(printf '%s' "$err" | grep -c 'no version in .*debian/changelog') $(find "$WORK/out-nopasstversion" -name '*.deb' 2>/dev/null | wc -l)"
links libgcc-s1 libseccomp2
check "binaries that link no libc6 are refused, and say that the list has none" "1 1 0" \
	"$rc $(printf '%s' "$err" | grep -c 'do not include libc6') $(find "$last_out" -name '*.deb' 2>/dev/null | wc -l)"
printf '#!/bin/sh\n[ "$1" = -S ] && exit 1\nexec "%s" "$@"\n' "$real_dpkg" > "$WORK/fakeldd/dpkg"
links libc6
check "a library that no package owns stops the build with a message" "1 1" "$rc $(printf '%s' "$err" | grep -c 'could not work out which packages own the libraries')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
