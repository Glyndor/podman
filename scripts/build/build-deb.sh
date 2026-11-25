#!/usr/bin/env bash
#
# Build podman_<version>_<arch>.deb from three verified upstream source trees:
# Podman, netavark and aardvark-dns. Debian 13 carries netavark 1.14, which
# lacks the commands Podman 6 calls, so the matching network stack ships inside
# the package and replaces the distribution's copy. Runs on Debian 13 with the
# build dependencies installed; the workflow does the install in a job that
# holds no secrets, and nothing touches the .deb after this script writes it.
#
# Usage: build-deb.sh <podman-src> <netavark-src> <aardvark-dns-src> <version> <output-dir>
#   <version> is the release version without the v: 6.2.0 or 6.2.0+r2

set -euo pipefail

podman_src="$(cd "${1:?podman source dir}" && pwd)"
netavark_src="$(cd "${2:?netavark source dir}" && pwd)"
aardvark_src="$(cd "${3:?aardvark-dns source dir}" && pwd)"
version="${4:?version without the v}"
out="$(mkdir -p "${5:?output dir}" && cd "$5" && pwd)"
arch="$(dpkg --print-architecture)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || { echo "bad version: $version" >&2; exit 1; }

stage="$(mktemp -d)"
work="$(mktemp -d)"
trap 'rm -rf "$stage" "$work"' EXIT

# The go of the build image comes from trixie-backports and is newer than the one go.mod asks
# for, so it builds Podman itself. GOTOOLCHAIN=auto stays for the day go.mod asks for a newer
# one than the archive has: the go command then fetches that toolchain, and the module proxy
# checks it against the Go checksum database.
export GOTOOLCHAIN=auto
# containers_image_openpgp uses Go's own OpenPGP instead of gpgme, and the build
# image has no subid or sqlite headers, so Podman links only libseccomp. That is
# what lets one package install on Debian 13 and on Ubuntu 24.04 and 26.04,
# whose gpgme and subid libraries have different names.
# Podman's own Makefile picks the apparmor and btrfs tags when it finds their headers,
# and the build image has them, so Debian's AppArmor profile support and the btrfs
# storage driver are on as they are in Debian's package. Neither links a shared library.
#
# What Fedora's spec for this release does, and Debian's package does too: build with
# -trimpath (the Makefile sets it as a make variable, which go never sees), a position
# independent executable, control-flow protection and full RELRO. The commit date and
# an origin go into the binary so the same tag gives the same Podman.
export GOFLAGS="-trimpath -buildmode=pie"
# Control-flow protection is spelled differently per architecture: -fcf-protection is
# x86 only (gcc refuses it on arm64), whose counterpart is -mbranch-protection.
case "$arch" in
	amd64) flow_protection="-fcf-protection=full" ;;
	arm64) flow_protection="-mbranch-protection=standard" ;;
	*) flow_protection="" ;;
esac
export CGO_CFLAGS="-O2 -g $flow_protection -D_FORTIFY_SOURCE=2"
export CGO_LDFLAGS="-Wl,-z,relro -Wl,-z,now"
SOURCE_DATE_EPOCH="$(git -C "$podman_src" log -1 --format=%ct 2>/dev/null || date +%s)"
export SOURCE_DATE_EPOCH
make -C "$podman_src" PREFIX=/usr EXTRA_BUILDTAGS=containers_image_openpgp \
	BUILD_INFO="$SOURCE_DATE_EPOCH" BUILD_ORIGIN="Glyndor" >&2
# The binary has to carry what was asked for; a Makefile that stops passing a flag
# along would otherwise ship without it and nothing would say so. A build that
# cannot read the build info is refused too: skipping the check when go or the
# binary is missing would ship exactly the package this exists to stop.
command -v go >/dev/null || { echo "no go to read the build info of the built podman" >&2; exit 1; }
[ -f "$podman_src/bin/podman" ] || { echo "make left no bin/podman to check" >&2; exit 1; }
built="$(go version -m "$podman_src/bin/podman")" \
	|| { echo "cannot read the build info of bin/podman" >&2; exit 1; }
for want in '-trimpath=true' '-buildmode=pie' 'apparmor' 'seccomp' 'systemd'; do
	printf '%s' "$built" | grep -q -- "$want" || { echo "the built podman lacks $want" >&2; exit 1; }
done
make -C "$podman_src" install PREFIX=/usr DESTDIR="$stage" >&2
# `install` does not put the shell completions in place; Debian's own package ships
# them, so a customer who moves to this one would otherwise lose tab completion.
# A shell tab completion is generated from the binary just built, so this runs after.
make -C "$podman_src" install.completions PREFIX=/usr DESTDIR="$stage" >&2

# The containers-common configuration of this release (0.70 for Podman 6.2.0), which
# upstream's spec requires at 0.68 or newer. Debian 13, Ubuntu 24.04 and 26.04 carry
# 0.62, 0.57 and 0.66: their seccomp profile, for one, lacks the futex_wait family and
# on 24.04 fchmodat2. The package provides it instead of depending on the distribution's.
common_version="$("$(dirname "$0")/install-common-config.sh" "$podman_src" "$stage" "${GLYNDOR_SHORTNAMES:-/usr/share/glyndor-build/shortnames.conf}")"

# The Rust components install into /usr/libexec/podman, a directory Podman
# searches for its helpers.
# --locked makes cargo build exactly the dependency versions in the Cargo.lock of the
# signed tag and fail if they would change. netavark's Makefile adds it only when
# CI is set, so without this a build could pick newer crates than upstream tested.
# Podman needs nothing: its Go modules come from the vendor tree of the tag.
for src in "$netavark_src" "$aardvark_src"; do
	[ -f "$src/Cargo.lock" ] || { echo "$src has no Cargo.lock to build against" >&2; exit 1; }
	make -C "$src" CARGO="cargo --locked" >&2
	make -C "$src" install PREFIX=/usr DESTDIR="$stage" >&2
done

# passt and pasta, from Debian's signed source of a release newer than the 20260716 that
# upstream's spec asks for: the passt of the supported releases is older and lacks an
# option Podman 6.2.0 always passes, so rootless networking would not start on Ubuntu
# 24.04. Built with the hardening flags Debian builds it with, and installed with
# its AppArmor profiles, as Debian's package does.
passt_src="${GLYNDOR_PASST_SRC:-/usr/share/glyndor-build/passt}"
[ -f "$passt_src/Makefile" ] || { echo "no passt source at $passt_src" >&2; exit 1; }
passt_version="$(dpkg-parsechangelog -l "$passt_src/debian/changelog" -S Version)"
[ -n "$passt_version" ] || { echo "no version in $passt_src/debian/changelog: the package would declare Provides: passt (= )" >&2; exit 1; }
case "$arch" in amd64) passt_target=x86_64 ;; arm64) passt_target=aarch64 ;; *) passt_target="$(uname -m)" ;; esac
(
	# eval runs what dpkg-buildflags prints, and its sh export escapes nothing: each
	# value goes inside double quotes with $ and backticks left as they are (dpkg 1.23,
	# DEB_CFLAGS_APPEND='$(x)' comes out as $(x)). It is safe here because no input of
	# it comes from the sources being built: dpkg's defaults in the build image, which
	# is pinned by digest, the DEB_* variables, which only this line sets (the image
	# and the workflow's docker run pass none), the build path, which dpkg leaves out
	# when it holds a character that would need quoting, and a debian/changelog in the
	# working directory, of which the build container has none (it runs from /).
	# Running this from a source tree, or feeding it anything taken from upstream,
	# would end that.
	eval "$(DEB_BUILD_MAINT_OPTIONS=hardening=+all dpkg-buildflags --export=sh)"
	export VERSION="$passt_version"
	make -C "$passt_src" prefix=/usr TARGET="$passt_target" >&2
	make -C "$passt_src" install prefix=/usr TARGET="$passt_target" DESTDIR="$stage" >&2
)
[ -x "$stage/usr/bin/passt" ] || { echo "passt did not install an executable usr/bin/passt for pasta to be linked to" >&2; exit 1; }
ln -f "$stage/usr/bin/passt" "$stage/usr/bin/pasta"
[ ! -e "$stage/usr/bin/passt.avx2" ] || ln -f "$stage/usr/bin/passt.avx2" "$stage/usr/bin/pasta.avx2"
if [ -d "$passt_src/contrib/apparmor" ]; then
	for f in "$passt_src"/contrib/apparmor/usr.bin.*; do
		[ -f "$f" ] && install -D -m 0644 "$f" "$stage/etc/apparmor.d/$(basename "$f")"
	done
	for f in "$passt_src"/contrib/apparmor/abstractions/*; do
		[ -f "$f" ] && install -D -m 0644 "$f" "$stage/etc/apparmor.d/abstractions/$(basename "$f")"
	done

	# When the last container of a rootless bridge network stops, Podman sends SIGTERM to
	# the pasta of the rootless network namespace. Ubuntu confines /usr/bin/podman under a
	# profile named `podman` (flags=(unconfined)), and abstractions/base admits a signal
	# only from peer=unconfined, so the kernel refuses it:
	#   apparmor="DENIED" operation="signal" class="signal" profile="pasta" comm="podman"
	#   requested_mask="receive" denied_mask="receive" signal=term peer="podman"
	# and the API answers 500 "rootless netns: kill network process: permission denied".
	# The rule goes inside the profile of pasta, after its one include of the abstraction,
	# and not into abstractions/pasta, which is a list of rules that anything may include.
	# upstream ships no local/usr.bin.pasta to hold it. It admits SIGTERM, the only signal
	# Podman 6.2 sends to that pasta, from that one peer; nothing wider. If upstream changes the shape of
	# the profile, or starts carrying such a rule itself, the build stops and says so.
	pasta_profile="$stage/etc/apparmor.d/usr.bin.pasta"
	pasta_anchor="  include <abstractions/pasta>"
	pasta_rule="  signal (receive) set=(term) peer=podman,"
	[ -f "$pasta_profile" ] || { echo "passt ships no AppArmor profile for pasta to add the signal rule to" >&2; exit 1; }
	[ "$(grep -c -x -F -- "$pasta_anchor" "$pasta_profile")" -eq 1 ] \
		|| { echo "the pasta profile does not include its abstraction exactly once, so the signal rule has nowhere to go" >&2; exit 1; }
	awk -v anchor="$pasta_anchor" -v rule="$pasta_rule" '
		$0 == anchor {
			print
			print ""
			print "  # Podman stops the pasta of the rootless network namespace with SIGTERM from its own"
			print "  # profile, which abstractions/base does not admit. Added by the Glyndor package:"
			print "  #   apparmor=\"DENIED\" operation=\"signal\" profile=\"pasta\" comm=\"podman\" signal=term peer=\"podman\""
			print rule
			next
		}
		{ print }' "$pasta_profile" > "$work/usr.bin.pasta"
	install -m 0644 "$work/usr.bin.pasta" "$pasta_profile"
	# Counted over everything the profile can reach, so a rule of upstream's own is a
	# second one and stops the build instead of sitting beside ours. The peer is read as a
	# token, in any spelling the syntax allows (signal(receive), peer = podman), and a peer
	# whose name only starts with podman is another peer.
	[ "$(cat "$pasta_profile" "$stage"/etc/apparmor.d/abstractions/* | grep -c -E '^[[:space:]]*signal([[:space:]]|\().*peer[[:space:]]*=[[:space:]]*"?podman"?([[:space:],]|$)')" -eq 1 ] \
		|| { echo "the pasta profile does not hold exactly one signal rule for peer=podman after the build added it" >&2; exit 1; }
	command -v apparmor_parser >/dev/null || { echo "no apparmor_parser to check the pasta profile with" >&2; exit 1; }
	# -Q does not load anything and -K writes no cache: the profile is only compiled, against
	# the distribution's abi and abstractions with the package's own on top.
	apparmor_parser -Q -K -b /etc/apparmor.d -I "$stage/etc/apparmor.d" "$pasta_profile" >/dev/null \
		|| { echo "the pasta profile with the signal rule does not compile" >&2; exit 1; }
else
	# A passt tree that moved or dropped the folder would give a package with no AppArmor
	# profile for pasta and no rule, and nothing would say so.
	echo "passt has no contrib/apparmor directory, so the package would ship no AppArmor profiles" >&2; exit 1
fi

# Every ELF in the package, listed once. The checks below read binaries, and an executable
# bit does not make a file one: passt installs doc/demo.sh with it, ldd exits non-zero on a
# script, and under pipefail that stopped the build after the package was complete.
: > "$work/elf"; : > "$work/dynamic"
while IFS= read -r -d '' f; do
	if file -b "$f" | grep -q '^ELF'; then
		printf '%s\0' "$f" >> "$work/elf"
		# ldd also refuses a static binary, so only what has a dynamic section goes to it.
		if readelf -d "$f" 2>/dev/null | grep -q '(NEEDED)'; then printf '%s\0' "$f" >> "$work/dynamic"; fi
	fi
done < <(find "$stage" -type f -print0)

# Release artifacts ship stripped (releases standard): drop debug symbols from every ELF.
xargs -0 -r strip --strip-unneeded < "$work/elf"
# A binary that still has debug sections means strip did not run: say so rather than ship 75 MB.
while IFS= read -r -d '' f; do
	! readelf -S "$f" 2>/dev/null | grep -q '\.debug_' || { echo "$f still has debug sections" >&2; exit 1; }
done < "$work/elf"

# The newest glibc symbol any binary asks for. libc6 has to be declared with it:
# without a version apt installs the package on a release whose glibc is older
# and every binary then fails to start (measured on Ubuntu 22.04, where netavark
# needs 2.39 and the release has 2.35).
# Not reading it is a failure: a fallback version would declare a floor the binaries
# do not have, and Ubuntu 22.04 would install a package that cannot start there.
glibc_min="$(xargs -0 -r objdump -T < "$work/dynamic" \
	| grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -V | tail -n 1)" \
	|| { echo "could not read the glibc symbols the binaries ask for" >&2; exit 1; }

# Shared libraries the binaries really link against, as Debian package names.
libs="$(xargs -0 -r ldd < "$work/dynamic" \
	| awk '$3 ~ /^\// {print $3}' | sort -u \
	| xargs -r -n1 realpath | xargs -r dpkg -S 2>/dev/null \
	| sed 's/:[a-z0-9]*:.*//; s/: .*//' | sort -u \
	| sed "s/^libc6\$/libc6 (>= ${glibc_min})/" | paste -sd, | sed 's/,/, /g')" \
	|| { echo "could not work out which packages own the libraries the binaries link" >&2; exit 1; }
# Every dynamic binary links libc: no libc6 means the pipeline lost its input, and the package would declare no libraries at all.
case ",${libs// /}," in
	*,libc6\(*) ;;
	*) echo "the libraries the binaries link do not include libc6 (got: ${libs:-nothing}): refusing a package that declares none" >&2; exit 1 ;;
esac

# These libraries are renamed between Debian and Ubuntu releases; a binary linked
# to one would not start elsewhere, so a build that picks one up is refused.
case ",$libs," in
	*gpgme*|*assuan*|*subid*|*sqlite*|*apparmor*|*btrfs*)
		echo "build links a library that differs between releases: $libs" >&2
		exit 1 ;;
esac

# Debian's aardvark-dns asks for netavark (>> 1.14), and an unversioned Provides does
# not satisfy a versioned dependency, so the Provides carries the versions built here.
crate_version() { awk -F'"' '/^version *=/ {print $2; exit}' "$1/Cargo.toml"; }
netavark_version="$(crate_version "$netavark_src")"
aardvark_version="$(crate_version "$aardvark_src")"
[[ "$netavark_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$aardvark_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| { echo "cannot read the netavark or aardvark-dns version from Cargo.toml" >&2; exit 1; }

# A host that ran the distribution's Podman keeps the crun that came with it. Ubuntu 24.04
# ships 1.14, which cannot read the runtime spec Podman 6 writes ("unknown version
# specified"), and Podman prefers crun over runc, so the Depends alternative is not enough:
# the old crun has to go, and runc takes its place.
mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: podman
Version: $version
Architecture: $arch
Maintainer: Glyndor <noreply@glyndor.net>
Section: admin
Priority: optional
Homepage: https://podman.io
Depends: conmon (>= 2.1.7), crun (>= 1.21) | runc, catatonit, init-system-helpers, nftables${libs:+, $libs}
Recommends: ca-certificates, uidmap, dbus-user-session, criu
Provides: netavark (= $netavark_version), aardvark-dns (= $aardvark_version), golang-github-containers-common (= $common_version), podman-remote, passt (= $passt_version)
Conflicts: netavark, aardvark-dns, golang-github-containers-common, podman-remote, passt
Breaks: crun (<< 1.21)
Replaces: netavark, aardvark-dns, golang-github-containers-common, podman-remote, passt
Description: Podman with its network stack, built from the upstream releases
 Daemonless container engine, packaged from the signed upstream tags of Podman,
 netavark and aardvark-dns, with the containers-common configuration it asks for.
 The network components and that configuration replace the older copies the
 distributions ship.
CONTROL

# /etc/containers belongs to the administrator and this package puts nothing in it. Releases
# before config_free_since shipped /etc/containers/policy.json as a plain file of the package, the
# policy that says which images may be pulled, so on an upgrade from one of those dpkg removes the
# file, edited or not, because the new package no longer lists it. preinst sets an edited one
# aside, which is any file whose sum is not one of the defaults those releases shipped, and
# postinst puts it back. When there is no file in /etc at the end of a first install or of that
# upgrade, postinst copies the default of /usr/share/containers there: buildah and skopeo of
# Debian and Ubuntu read the policy only from /etc/containers, and Podman falls back to /usr/share.
# Nothing is a conffile, so dpkg never asks; a file deleted by the administrator after that is not
# put back by later upgrades. Sums: the empty file of releases 6.2.0 to 6.2.0+r6 and the default of
# 6.2.0+r7 to 6.2.0+r11.
config_free_since="6.2.0+r12"
known_policy_sums="d41d8cd98f00b204e9800998ecf8427e ff61005e84c18498ed1b9d3f1b48db0a"
cat > "$stage/DEBIAN/preinst" <<PREINST
#!/bin/sh
set -e
if [ "\$1" = upgrade ] && dpkg --compare-versions "\$2" lt "$config_free_since"; then
	f="\${DPKG_ROOT:-}/etc/containers/policy.json"
	if [ -f "\$f" ] && [ ! -L "\$f" ]; then
		sum="\$(md5sum < "\$f" | cut -d' ' -f1)"
		case " $known_policy_sums " in
			*" \$sum "*) ;;
			*) cp -p "\$f" "\$f.glyndor-kept" ;;
		esac
	fi
fi
exit 0
PREINST
chmod 0755 "$stage/DEBIAN/preinst"

# The AppArmor profiles of passt are loaded when the package is configured, as Debian's
# package does; without it they would only apply after the next boot. A profile that does
# not load does not fail the installation, as in Debian's own snippet, but it says so.
#
# What postinst copies into /etc/containers is the package's own act, and a purge takes it away
# again, only when nobody changed it: the sum of the copy is written to /var/lib/glyndor-podman/policy.md5,
# and postrm purge removes the file when it still has that sum. An edited file stays, and so does one
# the administrator made, since no sum was written for it. A copy that an earlier release made (the
# release that stopped shipping the file copied it without a record) is adopted at the first
# configuration after this one when it is byte for byte the default of the package.
# A .glyndor-kept that is still there after the upgrade it was made for, because that was
# interrupted, is the administrator's file: it is put back when /etc has none, and kept under another name when
# /etc has a different one, never deleted.
cat > "$stage/DEBIAN/postinst" <<POSTINST
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
	root="\${DPKG_ROOT:-}"
	f="\$root/etc/containers/policy.json"
	rec="\$root/var/lib/glyndor-podman/policy.md5"
	record() {
		mkdir -p "\$root/var/lib/glyndor-podman"
		md5sum < "\$f" | cut -d' ' -f1 > "\$rec"
	}
	if [ -z "\$2" ] || dpkg --compare-versions "\$2" lt "$config_free_since"; then
		if [ -e "\$f.glyndor-kept" ] && [ ! -e "\$f" ]; then
			mv "\$f.glyndor-kept" "\$f"
			echo "podman: kept your /etc/containers/policy.json, which this package no longer ships" >&2
		elif [ ! -e "\$f" ] && [ ! -L "\$f" ]; then
			mkdir -p "\$root/etc/containers"
			cp -p "\$root/usr/share/containers/policy.json" "\$f"
			record
		fi
	fi
	if [ -e "\$f.glyndor-kept" ]; then
		if [ -e "\$f" ] && ! cmp -s "\$f.glyndor-kept" "\$f"; then
			mv "\$f.glyndor-kept" "\$f.glyndor-previous"
			echo "podman: an upgrade that was interrupted left your earlier /etc/containers/policy.json as policy.json.glyndor-previous" >&2
		else
			rm -f "\$f.glyndor-kept"
		fi
	fi
	if [ -f "\$f" ] && [ ! -L "\$f" ] && [ ! -e "\$rec" ] && [ -f "\$root/usr/share/containers/policy.json" ] \\
		&& cmp -s "\$f" "\$root/usr/share/containers/policy.json"; then
		record
	fi
fi
if [ "\$1" = configure ] && command -v apparmor_parser >/dev/null 2>&1 && aa-enabled >/dev/null 2>&1; then
	for p in usr.bin.passt usr.bin.pasta usr.bin.passt-repair usr.bin.pesto; do
		[ ! -f "/etc/apparmor.d/\$p" ] || apparmor_parser -r -T -W "/etc/apparmor.d/\$p" \\
			|| echo "podman: the AppArmor profile \$p did not load" >&2
	done
fi
exit 0
POSTINST
chmod 0755 "$stage/DEBIAN/postinst"

cat > "$stage/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = purge ]; then
	root="${DPKG_ROOT:-}"
	f="$root/etc/containers/policy.json"
	rec="$root/var/lib/glyndor-podman/policy.md5"
	if [ -f "$rec" ] && [ -f "$f" ] && [ ! -L "$f" ] && [ "$(md5sum < "$f" | cut -d' ' -f1)" = "$(cat "$rec")" ]; then
		rm -f "$f"
		rmdir "$root/etc/containers" 2> /dev/null || true
	fi
	rm -f "$rec"
	rmdir "$root/var/lib/glyndor-podman" 2> /dev/null || true
fi
exit 0
POSTRM
chmod 0755 "$stage/DEBIAN/postrm"

dpkg-deb --root-owner-group -Zxz --build "$stage" "$out/podman_${version}_${arch}.deb" >/dev/null
echo "$out/podman_${version}_${arch}.deb"
