#!/usr/bin/env bash
#
# Tests for scripts/package/require-tools.sh: a program of the list that the container lacks stops
# the build and is named, the second field of a line limits it to a format, and the list that is
# committed names the programs make and the documentation need.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/package/require-tools.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
run() { out="$(GLYNDOR_TOOLS_FILE="$WORK/list" "$SCRIPT" "$@" 2>&1)"; rc=$?; }

printf '# a comment\n\nbash\nno-such-tool-one rpm\nno-such-tool-two pacman\nno-such-tool-three\n' > "$WORK/list"
run rpm
check "an rpm build lacking a tool of everyone and a tool of rpm is refused, naming both" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'lacks: no-such-tool-one no-such-tool-three;')"
run pacman
check "a pacman build is not asked for the tool of rpm, and is asked for the one of pacman" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'lacks: no-such-tool-two no-such-tool-three;')"
printf 'bash\nsh rpm\n' > "$WORK/list"
run rpm
check "a list whose programs are all here passes" "0 1" "$rc $(printf '%s\n' "$out" | grep -c 'every program')"
run deb
check "a format that is not rpm or pacman is a usage error" 2 "$rc"
out="$(GLYNDOR_TOOLS_FILE="$WORK/absent" "$SCRIPT" rpm 2>&1)"; check "a list that is not there is refused, and says so" "1" "$(printf '%s\n' "$out" | grep -c "no list of build tools")"
"$SCRIPT" > /dev/null 2>&1; check "no format is refused" 1 "$?"

# The list as committed.
for tool in python3 envsubst go cargo protoc make gcc man perl awk sed grep install ln mktemp date cc pkg-config; do
	check "the committed list names $tool" 1 "$(grep -c -x "$tool" "$HERE/scripts/package/build-tools.txt")"
done
check "go-md2man is not asked of the distribution: Podman builds the one that makes the man pages" 0 "$(grep -c -x 'go-md2man' "$HERE/scripts/package/build-tools.txt")"
# Each program the Makefiles of Podman, netavark and aardvark-dns run has a package in the build dependencies
# of every rpm family: man and perl for the check of the man pages of Podman, awk and sed for the others.
for family in "fedora | el | amzn" suse; do
	block="$(sed -n "/^\t$family)/,/optional=/p" "$HERE/scripts/package/rpm/install-build-deps.sh")"
	for pkg in 'man' 'perl' 'gawk' 'sed' 'grep'; do
		check "the build dependencies of $family name a package of $pkg" 1 "$(printf '%s\n' "$block" | grep -c -E "(^|[[:space:]])($pkg|$pkg-db|$pkg-interpreter)([[:space:]]|\))")"
	done
done
# The image of every distribution installs the packages that carry the programs of the proof.
installs() { grep -E '^RUN ' "$1" | grep -q -E "$2"; }
for dockerfile in "$HERE"/scripts/package/images/*/Dockerfile; do
	id="$(basename "$(dirname "$dockerfile")")"
	got=0
	if installs "$dockerfile" 'util-linux' && installs "$dockerfile" 'shadow' && installs "$dockerfile" 'libcap'; then got=1; fi
	check "the image of $id installs util-linux, shadow and libcap, which carry runuser, useradd, newuidmap and getcap" 1 "$got"
done
check "and rpmbuild for rpm only, makepkg for pacman only" "rpmbuild rpm makepkg pacman" "$(grep -E '^(rpmbuild|makepkg)' "$HERE/scripts/package/build-tools.txt" | paste -sd' ')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
