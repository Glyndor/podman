#!/usr/bin/env bash
#
# Tests for the checks of scripts/verify/package-state.sh about what the installed
# package contains: the files a customer expects on disk (ships), the man pages and
# pasta in the list dpkg keeps (listed), the containers-common it provides (provides)
# and the version podman reports (version). The tree is a directory of this suite's,
# and dpkg and podman are faked, so every refusal is seen once, by what it says, next
# to the shape that passes. The other checks of the script are in package-state.test.sh.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/package-state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin"
# dpkg -L podman prints $FAKE_LIST, dpkg -s podman prints $FAKE_STATUS; either fails
# when $FAKE_DPKG_FAILS is set, as dpkg does for a package it does not know.
cat > "$WORK/bin/dpkg" <<'DPKG'
#!/bin/sh
[ "$2" = podman ] && [ -z "${FAKE_DPKG_FAILS:-}" ] || exit 1
case "$1" in
	-L) printf '%b' "$FAKE_LIST" ;;
	-s) printf '%b' "$FAKE_STATUS" ;;
	*) exit 2 ;;
esac
DPKG
printf '#!/bin/sh\n[ "$1" = --version ] && [ -z "${FAKE_PODMAN_FAILS:-}" ] || exit 9\necho "podman version $FAKE_VERSION"\n' > "$WORK/bin/podman"
chmod +x "$WORK/bin/dpkg" "$WORK/bin/podman"

run() { # <args...>: sets $rc and $err
	rc=0
	err="$(PATH="$WORK/bin:$PATH" GLYNDOR_PACKAGE_ROOT="$WORK/root" bash "$SCRIPT" "$@" 2>&1 >/dev/null)" || rc=$?
}
said() { printf '%s\n' "$err" | grep -c -x -F -- "$1"; }

# --- ships: the files a customer expects ---------------------------------------------
present="/usr/bin/podman /usr/bin/podman-remote /usr/libexec/podman/quadlet /usr/libexec/podman/rootlessport
/usr/lib/systemd/system/podman.socket /usr/lib/systemd/user/podman.socket
/usr/lib/systemd/system-generators/podman-system-generator /usr/lib/systemd/user-generators/podman-user-generator
/usr/lib/tmpfiles.d/podman.conf /usr/share/bash-completion/completions/podman /usr/share/zsh/site-functions/_podman
/usr/share/fish/vendor_completions.d/podman.fish"
configured="/etc/containers/policy.json /usr/share/containers/registries.conf /usr/share/containers/containers.conf
/usr/share/containers/registries.conf.d/000-shortnames.conf"
tree() { # a tree that ships everything, empty files where only presence is asked
	rm -rf "$WORK/root"
	local f
	for f in $present; do mkdir -p "$WORK/root${f%/*}"; : > "$WORK/root$f"; done
	for f in $configured; do mkdir -p "$WORK/root${f%/*}"; echo x > "$WORK/root$f"; done
	for f in netavark aardvark-dns; do printf '#!/bin/sh\n' > "$WORK/root/usr/libexec/podman/$f"; chmod +x "$WORK/root/usr/libexec/podman/$f"; done
}
tree
run ships
check "a tree with every file passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
missed=""
for f in $present $configured; do
	tree; rm "$WORK/root$f"
	run ships
	[ "$rc $(said "the package does not ship $f")" = "1 1" ] || missed="$missed $f"
done
check "each file gone is refused, and named" "" "${missed# }"
missed=""
for f in $configured; do
	tree; : > "$WORK/root$f"
	run ships
	[ "$rc $(said "the package does not ship $f")" = "1 1" ] || missed="$missed $f"
done
check "each configuration file left empty is refused, and named" "" "${missed# }"
for helper in netavark aardvark-dns; do
	tree; chmod -x "$WORK/root/usr/libexec/podman/$helper"
	run ships
	check "a $helper that is not executable is refused, and named" "1 1" "$rc $(said "missing $helper in the package")"
done
tree
run ships extra
check "ships with an argument is a usage error" 2 "$rc"

# --- listed: what dpkg says the package holds -----------------------------------------
list='/.\n/usr/bin/pasta\n/usr/bin/passt\n/usr/share/man/man1/podman-run.1.gz\n/usr/share/man/man1/podman.1.gz\n'
FAKE_LIST="$list" run listed
check "the man pages and pasta listed: passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
FAKE_LIST='/.\n/usr/bin/pasta\n/usr/share/doc/podman/README.md\n' run listed
check "no man page listed is refused" "1 1" "$rc $(said 'the package does not ship the man pages')"
FAKE_LIST='/.\n/usr/bin/pasta.avx2\n/usr/share/man/man1/podman-run.1.gz\n' run listed
check "a pasta.avx2 alone is not pasta: refused" "1 1" "$rc $(said 'the package does not ship pasta')"
FAKE_DPKG_FAILS=1 FAKE_LIST="$list" run listed
check "a dpkg that cannot list podman is refused for that" "1 1" "$rc $(said 'dpkg cannot list the files of podman')"

# --- provides: the containers-common buildah and skopeo depend on ---------------------
status='Package: podman\nProvides: netavark (= 2.1.0), golang-github-containers-common (= 0.70.0), passt (= 0.0)\n'
FAKE_STATUS="$status" run provides
check "containers-common 0.70 provided: passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
FAKE_STATUS='Package: podman\nProvides: netavark (= 2.1.0), golang-github-containers-common (= 0.57.4)\n' run provides
check "a containers-common older than 0.60 is refused" "1 1" "$rc $(said 'the package does not provide containers-common')"
FAKE_STATUS='Package: podman\nProvides: netavark (= 2.1.0), golang-github-containers-common\n' run provides
check "one provided with no version is refused" "1 1" "$rc $(said 'the package does not provide containers-common')"
FAKE_STATUS='Package: podman\nDepends: golang-github-containers-common (= 0.70.0)\n' run provides
check "one depended on and not provided is refused" "1 1" "$rc $(said 'the package does not provide containers-common')"
FAKE_DPKG_FAILS=1 FAKE_STATUS="$status" run provides
check "a podman dpkg does not know is refused for that" "1 1" "$rc $(said 'dpkg does not know podman')"

# --- version: the one that was built --------------------------------------------------
FAKE_VERSION=6.2.0 run version 6.2.0
check "podman reports the version built: passes" "0 0" "$rc $(printf '%s' "$err" | wc -c)"
FAKE_VERSION=6.1.0 run version 6.2.0
check "another version is refused, and named" "1 1" "$rc $(said 'version mismatch: podman version 6.1.0')"
FAKE_VERSION=6.2.0+r2 run version 6.2.0
check "a version with more after it is not the same version" "1 1" "$rc $(said 'version mismatch: podman version 6.2.0+r2')"
FAKE_PODMAN_FAILS=1 FAKE_VERSION=6.2.0 run version 6.2.0
check "a podman that cannot say its version is refused for that" "1 1" "$rc $(said 'podman --version failed')"
run version
check "version without the version built is a usage error" 2 "$rc"
for c in listed provides; do
	FAKE_LIST="$list" FAKE_STATUS="$status" run "$c" extra
	check "$c with an argument is a usage error, and says so" "2 1" "$rc $(said "$c takes no argument")"
done
run ships extra
check "and so is ships, by name" "2 1" "$rc $(said 'ships takes no argument')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
