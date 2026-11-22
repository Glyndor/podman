#!/usr/bin/env bash
#
# Tests for the signal rule scripts/build/build-deb.sh adds to pasta's AppArmor profile.
#
# Podman signals pasta with SIGTERM from the profile Ubuntu gives /usr/bin/podman, and the profile
# of pasta has to admit it or stopping the last container of a bridge network fails. The build
# adds one rule inside the profile and stops when it cannot: the shape of upstream's file is
# read, not assumed. The kernel is not here, so what these show is the text of the profile, that
# it was handed to apparmor_parser, and every way the build refuses; the profile loaded and the
# signal admitted are what the step "Stop the last container of a bridge network through the
# API, on the runner itself" of reusable-build.yml sees on the real package.
#
# Each case is a build of its own on a copy of the fake source tree with one edit, and the cases
# run at the same time: a build costs a third of a second, and the suite has fifteen. Nothing a
# case writes is shared with another, and the checks come after all of them have finished.
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

arch="$(dpkg --print-architecture)"
RULE='  signal (receive) set=(term) peer=podman,'
mkdir "$WORK/v"
A="contrib/apparmor"

# variant <name> <edit> [VAR=value ...]: a build on a copy of the tree, with <edit> run on the
# directory of passt's profiles ($a) first, and VAR=value in its environment. Its exit status, its
# stderr and what the fake apparmor_parser saw are left in $WORK/v/<name>. It runs in the background.
variant() {
	local name="$1" edit="$2" d a
	shift 2
	d="$WORK/v/$name"; mkdir "$d"
	cp -r "$WORK/src" "$WORK/nv" "$WORK/aa" "$WORK/passt" "$d/"
	# shellcheck disable=SC2034 # the edit reads it
	a="$d/passt/$A"
	eval "$edit"
	(
		export AA_CALLS="$d/aa.calls" AA_PROFILE="$d/aa.profile" GLYNDOR_PASST_SRC="$d/passt"
		rc=0
		env "$@" "$SCRIPT" "$d/src" "$d/nv" "$d/aa" 6.2.0 "$d/out" >/dev/null 2>"$d/err" || rc=$?
		echo "$rc" > "$d/rc"
	) &
}
# shellcheck disable=SC2034 # the edits read it
include='^  include <abstractions/pasta>$'

# No apparmor_parser on the PATH at all, which is an image that does not have the package. The
# directory of every tool the build needs is kept; only the ones that hold the parser are left out.
mkdir "$WORK/noaa"
for t in "$WORK"/fakebin/*; do [ "${t##*/}" = apparmor_parser ] || ln -s "$t" "$WORK/noaa/${t##*/}"; done
clean_path="$WORK/noaa"; old_ifs="$IFS"; IFS=:
for d in $PATH; do [ -x "$d/apparmor_parser" ] || clean_path="$clean_path:$d"; done
IFS="$old_ifs"

variant accepted ':'
variant no-profile 'rm "$a/usr.bin.pasta"'
variant no-include 'sed -i "s|$include|  include <abstractions/passt>|" "$a/usr.bin.pasta"'
variant two-includes 'sed -i "s|$include|&\n  include <abstractions/pasta>|" "$a/usr.bin.pasta"'
variant include-with-comment 'sed -i "s|$include|& # the pasta rules|" "$a/usr.bin.pasta"'
variant upstream-has-it 'echo "  signal (receive) set=(term) peer=podman," >> "$a/abstractions/pasta"'
variant spelling-1 'printf "%s\n" "  signal(receive) peer=podman," >> "$a/abstractions/pasta"'
variant spelling-2 'printf "%s\n" "  signal (receive) peer = podman," >> "$a/abstractions/pasta"'
variant spelling-3 'printf "%s\n" "  signal (receive) peer=\"podman\"," >> "$a/abstractions/pasta"'
variant spelling-4 'printf "\tsignal\t(send) peer=podman\n" >> "$a/abstractions/pasta"'
variant other-podman 'echo "  signal (receive) set=(term) peer=podman-other," >> "$a/abstractions/pasta"'
variant other-peer 'echo "  signal (receive) set=(term) peer=unconfined," >> "$a/abstractions/pasta"'
variant no-compile ':' FAKE_AA_FAILS=1
variant no-apparmor-dir 'mv "$a" "$a.away"'
variant no-parser ':' PATH="$clean_path"
wait

# What a case left: $rc, $err and the directory of its build.
result() { d="$WORK/v/$1"; rc="$(cat "$d/rc")"; err="$(cat "$d/err")"; }
# Each way the build cannot add the rule is a refusal that names it, and writes no package. The
# case before each shows the same build accepted, so a refusal is for the thing it names.
no_package() { check "and no package is written" 0 "$(find "$WORK/v/$1/out" -name '*.deb' 2>/dev/null | wc -l)"; }

PROF="$WORK/passt/contrib/apparmor/usr.bin.pasta"; ABS="$WORK/passt/contrib/apparmor/abstractions/pasta"
result accepted
deb="$d/out/podman_6.2.0_$arch.deb"; aa_calls="$(cat "$d/aa.calls" 2>/dev/null)"; aa_profile="$(cat "$d/aa.profile" 2>/dev/null)"
mkdir "$WORK/x-rule"; dpkg-deb -x "$deb" "$WORK/x-rule" 2>/dev/null
got="$WORK/x-rule/etc/apparmor.d/usr.bin.pasta"
check "a pasta profile of upstream's shape is accepted" 0 "$rc"
check "the rule is in the profile, once" 1 "$(grep -c -x -F -- "$RULE" "$got")"
check "and inside the profile, after its include of the abstraction" "inside, after the include" \
	"$(awk '/^profile pasta /{inp=1} /^}/{inp=0} $0=="  include <abstractions/pasta>"{inc=NR} $0==rule{at=NR; ins=inp}
		END{print (inc > 0 && at > inc && ins) ? "inside, after the include" : "elsewhere"}' rule="$RULE" "$got")"
check "and the only line added that is not a comment or a blank is the rule" "> $RULE" \
	"$(diff "$PROF" "$got" | grep '^>' | grep -v -e '^> *#' -e '^> *$')"
check "and nothing of upstream's profile was taken out" 0 "$(diff "$PROF" "$got" | grep -c '^<')"
check "and it admits no other signal, no other peer and no complain mode" 0 \
	"$(grep -v '^ *#' "$got" | grep -c -E 'peer=(\*|unconfined)|complain|signal \((send|receive,)|set=\(\*')"
check "and the abstraction is as upstream ships it" "" "$(cmp "$ABS" "$WORK/x-rule/etc/apparmor.d/abstractions/pasta" 2>&1)"
check "and the profile is not writable by others" "-rw-r--r--" \
	"$(dpkg-deb -c "$deb" 2>/dev/null | awk '$6 == "./etc/apparmor.d/usr.bin.pasta" {print $1}')"
check "apparmor_parser compiled it once, without loading it and without a cache" 1 \
	"$(printf '%s\n' "$aa_calls" | grep -c -E '^-Q -K -b /etc/apparmor.d -I [^ ]+/etc/apparmor.d [^ ]+/etc/apparmor.d/usr.bin.pasta$')"
check "and what it was given is the profile with the rule" 1 "$(printf '%s\n' "$aa_profile" | grep -c -x -F -- "$RULE")"
check "and the directory with the package's abstractions is the one on its include path" "same directory" \
	"$(printf '%s\n' "$aa_calls" | awk '{print ($6 != "" && $7 == $6 "/usr.bin.pasta") ? "same directory" : "different"}')"

result no-profile
check "no profile for pasta in passt's tree: refused, and named" "1 1" "$rc $(printf '%s' "$err" | grep -c 'passt ships no AppArmor profile for pasta')"
no_package no-profile
result no-include
check "a profile that no longer includes the abstraction: refused, and named" "1 1" \
	"$rc $(printf '%s' "$err" | grep -c 'does not include its abstraction exactly once')"
no_package no-include
result two-includes
check "a profile that includes it twice: refused, and named" "1 1" \
	"$rc $(printf '%s' "$err" | grep -c 'does not include its abstraction exactly once')"
no_package two-includes
result include-with-comment
check "an include that carries a comment is not the one the rule follows: refused, and named" "1 1" \
	"$rc $(printf '%s' "$err" | grep -c 'does not include its abstraction exactly once')"
no_package include-with-comment
result upstream-has-it
check "a rule for that peer that upstream now ships: refused, and named" "1 1" \
	"$rc $(printf '%s' "$err" | grep -c 'does not hold exactly one signal rule for peer=podman')"
no_package upstream-has-it
n=0
for variant in '  signal(receive) peer=podman,' '  signal (receive) peer = podman,' '  signal (receive) peer="podman",' "$(printf '\tsignal\t(send) peer=podman')"; do
	n=$((n + 1)); result "spelling-$n"
	check "upstream's rule spelled '$(printf '%s' "$variant" | tr '\t' ' ' | sed 's/^ *//')': refused, and named" "1 1" \
		"$rc $(printf '%s' "$err" | grep -c 'does not hold exactly one signal rule for peer=podman')"
	no_package "spelling-$n"
done
result other-podman
check "a peer whose name only starts with podman is not that peer: accepted, and the rule added once" "0 1" \
	"$rc $(grep -c -x -F -- "$RULE" "$d/aa.profile")"
result other-peer
check "a rule of upstream's for another peer is not in the way: accepted, and the rule added once" "0 1" \
	"$rc $(grep -c -x -F -- "$RULE" "$d/aa.profile")"
result no-compile
check "a profile apparmor_parser cannot compile: refused, and named" "1 1" "$rc $(printf '%s' "$err" | grep -c 'with the signal rule does not compile')"
no_package no-compile

# A passt tree that has no contrib/apparmor at all, as when upstream moves the folder: the same
# build is accepted above, and the package would otherwise ship without profiles.
result no-apparmor-dir
check "a passt tree with no contrib/apparmor: refused, and named" "1 1" \
	"$rc $(printf '%s' "$err" | grep -c 'passt has no contrib/apparmor directory')"
no_package no-apparmor-dir

# The postinst loads the profiles on configure. A copy of it with /etc pointed at a fixture runs
# with a parser that loads them and one that cannot: the installation goes on either way, as
# Debian's own snippet does, and the second says which profile did not load.
mkdir "$WORK/etc-aa"
dpkg-deb -e "$deb" "$WORK/ctl" 2>/dev/null
sed "s|/etc/apparmor.d|$WORK/etc-aa|g" "$WORK/ctl/postinst" > "$WORK/postinst"
: > "$WORK/etc-aa/usr.bin.passt"; : > "$WORK/etc-aa/usr.bin.pasta"
export AA_CALLS="$WORK/postinst.calls" AA_PROFILE="$WORK/postinst.profile"
rc=0; err="$(sh "$WORK/postinst" configure 2>&1 >/dev/null)" || rc=$?
check "configure loads the profiles that are there, and says nothing when they load" "0 2 0" \
	"$rc $(grep -c -E '^-r -T -W ' "$AA_CALLS") $(printf '%s' "$err" | grep -c .)"
rc=0; err="$(FAKE_AA_FAILS=1 sh "$WORK/postinst" configure 2>&1 >/dev/null)" || rc=$?
check "a profile that does not load does not fail the installation, and each one is named" "0 1 1" \
	"$rc $(printf '%s\n' "$err" | grep -c -x 'podman: the AppArmor profile usr.bin.passt did not load') $(printf '%s\n' "$err" | grep -c -x 'podman: the AppArmor profile usr.bin.pasta did not load')"
check "and the profile that is not there is not named" 0 "$(printf '%s\n' "$err" | grep -c 'usr.bin.pesto')"

result no-parser
check "an image with no apparmor_parser: refused, and named" "1 1" "$rc $(printf '%s' "$err" | grep -c 'no apparmor_parser to check the pasta profile with')"
no_package no-parser

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
