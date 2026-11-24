#!/usr/bin/env bash
#
# Tests for scripts/package/rpm/install-build-deps.sh with a dnf and a zypper that write down
# what they were asked: the packages of a family are required, the ones that may be absent are
# not, the repository of the RHEL headers is switched on only there, and a package the
# repositories lack, or a family nobody knows, stops the build and says so.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/rpm/install-build-deps.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin"
cat > "$WORK/bin/dnf" <<'PM'
#!/bin/sh
echo "dnf $*" >> "$CALLS"
case "$1" in
	repolist) printf 'repo id   repo name\nbaseos    BaseOS\ncrb       CRB\nappstream AppStream\n'; exit 0 ;;
	install) case " $* " in *" $FAKE_MISSING "*) exit 1 ;; esac ;;
esac
exit 0
PM
cat > "$WORK/bin/zypper" <<'PM'
#!/bin/sh
echo "zypper $*" >> "$CALLS"
case " $* " in *" $FAKE_MISSING "*) exit 1 ;; esac
exit 0
PM
# The programs the build needs, so the check that they are there passes on a machine that has not got them.
while read -r tool _; do
	case "$tool" in '' | '#'*) continue ;; esac
	# Only a stand-in for what the machine lacks: sed, grep and install of the tests themselves stay real.
	[ -e "$WORK/bin/$tool" ] || [ -n "$(command -v "$tool")" ] || printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$tool"
	[ ! -e "$WORK/bin/$tool" ] || chmod +x "$WORK/bin/$tool"
done < "$HERE/scripts/package/build-tools.txt"
chmod +x "$WORK/bin/dnf" "$WORK/bin/zypper"
printf 'gcc\nno-such-tool-xyz\n' > "$WORK/tools"
export CALLS="$WORK/calls"
PATH="$WORK/bin:$PATH"
run() { : > "$CALLS"; out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }
calls() { grep -c -- "$1" "$CALLS"; }

run fedora
check "Fedora: the build succeeds" 0 "$rc"
check "and python3 is installed, which the documentation of Podman is generated with" 1 "$(calls "gettext python3")"
check "and the toolchain, the headers and rpmbuild are installed in one transaction" 1 "$(calls 'dnf install -y --setopt=install_weak_deps=False rpm-build gcc make git-core pkgconf-pkg-config golang cargo rust glibc-devel libseccomp-devel systemd-devel libselinux-devel protobuf-compiler gettext')"
check "and man-db, perl, gawk, sed and grep, which the docs and the Makefiles of netavark and aardvark-dns run" 1 "$(calls 'man-db perl-interpreter gawk sed grep')"
check "and the headers of btrfs are asked for apart" 1 "$(calls 'btrfs-progs-devel')"
check "and no extra repository is switched on" 0 "$(calls 'config-manager')"
run el
check "RHEL family: the build succeeds" 0 "$rc"
check "and the repository of the headers is switched on, by the name the clone gives it" 1 "$(calls 'dnf config-manager --set-enabled crb')"
check "and it is the only one" 1 "$(calls 'config-manager')"
run amzn; check "Amazon Linux builds with dnf" 0 "$rc"
check "and with no extra repository" 0 "$(calls 'config-manager')"
run suse
check "openSUSE: the build succeeds" 0 "$rc"
check "and its repositories are refreshed, trusting the keys they offer once" 1 "$(calls 'zypper --non-interactive --gpg-auto-import-keys refresh')"
check "and the packages are the ones of that family" 1 "$(calls 'zypper --non-interactive install --no-recommends rpm-build gcc make git-core pkgconf-pkg-config go cargo rust')"
check "and man, perl, gawk, sed and grep, with the names openSUSE gives them" 1 "$(calls 'man perl gawk sed grep')"
check "and the btrfs headers are libbtrfs-devel there" 1 "$(calls 'libbtrfs-devel')"

FAKE_MISSING=golang run fedora
check "a required package the repositories lack stops the build" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'lack a package the build requires')"
FAKE_MISSING=btrfs-progs-devel run fedora
check "a missing btrfs header does not: the build goes without btrfs" "0 1" "$rc $(printf '%s\n' "$out" | grep -c 'goes without btrfs')"
GLYNDOR_TOOLS_FILE="$WORK/tools" run fedora
check "a program the build runs that the container lacks stops the build before it starts, and is named" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'lacks: no-such-tool-xyz')"
run gentoo; check "a family nobody knows is a usage error" "2 1" "$rc $(printf '%s\n' "$out" | grep -c 'no build dependencies are known')"
"$SCRIPT" > /dev/null 2>&1; check "no family is refused" 1 "$?"

# The dependencies packaged beside podman bring their own build dependencies, by the name the family gives them.
run fedora crun,catatonit,conmon,passt
check "Fedora with all four extras: the build succeeds" 0 "$rc"
check "and the headers of libcap and json-c are asked for, which the configure of crun needs" 1 "$(calls 'libcap-devel json-c-devel')"
check "and the autotools and the static libc, which catatonit is built and linked with" 1 "$(calls 'autoconf automake libtool glibc-static')"
check "and the headers of glib, which conmon includes" 1 "$(calls 'glib2-devel')"
run suse crun,catatonit
check "openSUSE names them libjson-c-devel and glibc-devel-static" "1 1" "$(calls 'libcap-devel libjson-c-devel') $(calls 'autoconf automake libtool glibc-devel-static')"
run amzn catatonit
check "a row that takes only catatonit does not install the headers of json-c" 0 "$(calls 'json-c-devel')"
run el
check "a row that takes no extras installs none of them" 0 "$(calls 'libcap-devel')"
run fedora passt
check "passt needs nothing beyond the compiler" "0 0" "$rc $(calls 'glib2-devel')"
run fedora nonesuch
check "an extra nobody knows is a usage error that names it" "2 1" "$rc $(printf '%s\n' "$out" | grep -c 'no build dependencies are known for the extra nonesuch')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
