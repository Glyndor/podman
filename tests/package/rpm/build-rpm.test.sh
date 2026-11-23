#!/usr/bin/env bash
#
# Tests for scripts/package/rpm/build-rpm.sh with a rpmbuild that writes down what it was
# asked: every value the spec says to the package manager comes from the row of the
# distribution, the version is the one of the contract, and a payload that was not built, a
# version without its revision or a distribution that is not an rpm one is refused.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/rpm/build-rpm.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin" "$WORK/payload"
# rpmbuild: records the defines, and puts a package where rpmbuild puts it.
cat > "$WORK/bin/rpmbuild" <<'RB'
#!/bin/sh
echo "$*" > "$CALLS"
for a in "$@"; do case "$a" in _topdir*) top="${a#_topdir }" ;; esac; done
prev=""
for a in "$@"; do [ "$prev" = --define ] && case "$a" in "_topdir "*) top="${a#_topdir }" ;; esac; prev="$a"; done
mkdir -p "$top/RPMS/x86_64" "$top/RPMS/noarch"
: > "$top/RPMS/x86_64/podman-1.x86_64.rpm"; : > "$top/RPMS/noarch/podman-docker-1.noarch.rpm"
RB
chmod +x "$WORK/bin/rpmbuild"
printf 'NETAVARK_VERSION=2.1.0\nAARDVARK_VERSION=2.1.3\nCOMMON_VERSION=0.70.0\n' > "$WORK/payload/facts.env"
export CALLS="$WORK/calls"
PATH="$WORK/bin:$PATH"
build() { out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
defined() { tr ' ' '\n' < "$WORK/calls" | sed -n "s/^$1\$//p" > /dev/null; grep -o -- "--define $1 [^ ]*" "$WORK/calls" | head -n 1 | cut -d' ' -f3; }

build "$WORK/payload" fc45 6.2.0+r12 "$WORK/out"
check "a build of a Fedora package succeeds" 0 "$rc"
check "and lists the packages it made" "$WORK/out/podman-1.x86_64.rpm" "$(printf '%s\n' "$out" | grep 'x86_64.rpm')"
check "the architecture packages and the noarch ones are both collected" "podman-1.x86_64.rpm podman-docker-1.noarch.rpm" "$(ls "$WORK/out" | paste -sd' ')"
check "the version is the one given, with its revision" "6.2.0+r12" "$(defined gl_version)"
check "the release counter is the revision" "12" "$(defined gl_release)"
check "the epoch is the one of the table" "5" "$(defined gl_epoch)"
check "the id is the one of the file names" "fc45" "$(defined gl_id)"
check "the family is the table's" "fedora" "$(defined gl_family)"
check "the epoch of netavark is the one of the distribution" "2" "$(defined gl_nv_epoch)"
check "the epoch and the number of containers-common follow the table: upstream's own on Fedora" "5 0.70.0" "$(defined gl_cc_epoch) $(defined gl_cc_version)"
check "the oldest passt is the table's" "0^20260716" "$(defined gl_passt_min)"
check "the versions of the network stack are read from the payload" "2.1.0 2.1.3" "$(defined gl_netavark) $(defined gl_aardvark)"
check "the payload is the directory given" "$WORK/payload" "$(defined gl_payload)"

# A distribution that numbers containers-common with Podman's own version gets it in the spec.
cat > "$WORK/table" <<'T'
el9|rpm|el|x86_64|6|3|5|podman|0^20260716|
pm1|pacman|arch|x86_64|0|0|1|upstream|0^20260716|
T
GLYNDOR_DISTROS_FILE="$WORK/table" build "$WORK/payload" el9 6.2.0+r3 "$WORK/out2"
check "on a distribution that numbers it with Podman, containers-common is the version of the package" "5 6.2.0+r3 3" "$(defined gl_cc_epoch) $(defined gl_cc_version) $(defined gl_nv_epoch)"
GLYNDOR_DISTROS_FILE="$WORK/table" build "$WORK/payload" pm1 6.2.0+r3 "$WORK/out3"
check "a pacman distribution is refused" "1 1" "$rc $(says 'pm1 is not an rpm distribution')"

for bad in 6.2.0 6.2.0+r 6.2.0-1 v6.2.0+r1 '6.2.0+r1 x'; do
	build "$WORK/payload" fc45 "$bad" "$WORK/out4"
	check "the version '$bad' is refused" "1 1" "$rc $(says 'bad version, expected X.Y.Z+rR')"
done
build "$WORK/payload" nope 6.2.0+r1 "$WORK/out4"; check "an unknown distribution is refused" 1 "$rc"
mkdir "$WORK/empty"
build "$WORK/empty" fc45 6.2.0+r1 "$WORK/out4"; check "a payload that was not built is refused" "1 1" "$rc $(says 'the payload was not built')"
for key in NETAVARK_VERSION AARDVARK_VERSION COMMON_VERSION; do
	mkdir -p "$WORK/p2"; grep -v "^$key" "$WORK/payload/facts.env" > "$WORK/p2/facts.env"
	build "$WORK/p2" fc45 6.2.0+r1 "$WORK/out4"; check "a payload whose facts lack $key is refused" "1 1" "$rc $(says "facts.env has no $key")"
done
"$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
