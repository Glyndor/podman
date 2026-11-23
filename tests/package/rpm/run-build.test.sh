#!/usr/bin/env bash
#
# Tests for scripts/package/rpm/run-build.sh: the steps of a build run in their order with the
# arguments each one needs, the short-name list is the one the distribution's package ships,
# and a distribution whose package has none stops the build. The scripts it calls are fakes
# that write down how they were called.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/rpm/run-build.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# The scripts directory the build reads: the real table, and fakes for what runs in a container.
mkdir -p "$WORK/scripts/package/rpm" "$WORK/src/podman" "$WORK/bin"
cp "$HERE/scripts/package/distros.sh" "$HERE/scripts/package/distros.txt" "$WORK/scripts/package/"
for s in package/rpm/install-build-deps.sh package/rpm/check-replacement.sh package/build-payload.sh package/rpm/build-rpm.sh package/rpm/build-extras.sh; do
	printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n[ -z "$FAKE_FAIL" ] || [ "$FAKE_FAIL" != "%s" ] || exit 1\n' "$s" "$s" > "$WORK/scripts/$s"
done
mkdir "$WORK/shortnames-dir"; echo '[aliases]' > "$WORK/shortnames-dir/000-shortnames.conf"
# dnf and zypper install the package; rpm lists its files and says where the short names are.
printf '#!/bin/sh\necho "$0 $*" >> "$CALLS"\n[ -z "$FAKE_NO_COMMON" ] || exit 1\n' > "$WORK/bin/dnf"
cp "$WORK/bin/dnf" "$WORK/bin/zypper"
cat > "$WORK/bin/rpm" <<'RPM'
#!/bin/sh
case "$1" in
	-qa) echo containers-common ;;
	-ql) [ -n "$FAKE_NO_SHORTNAMES" ] || echo "$SHORTNAMES_DIR/000-shortnames.conf" ;;
esac
RPM
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/git"
chmod +x "$WORK/bin/dnf" "$WORK/bin/zypper" "$WORK/bin/rpm" "$WORK/bin/git" "$WORK"/scripts/package/*.sh "$WORK"/scripts/package/rpm/*.sh 2>/dev/null
export CALLS="$WORK/calls" SHORTNAMES_DIR="$WORK/shortnames-dir" GLYNDOR_SRC="$WORK/src" GLYNDOR_SCRIPTS="$WORK/scripts" HOME="$WORK/home"
mkdir "$HOME"
PATH="$WORK/bin:$PATH"
run() { : > "$CALLS"; out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

run fc45 6.2.0+r12 "$WORK/out"
check "a build on Fedora succeeds" 0 "$rc"
check "its steps run in order: dependencies, the package that holds the short names, the payload, the rpm" \
	"install-build-deps|check-replacement|dnf|build-payload|build-rpm|build-extras" "$(sed 's|^package/rpm/||; s|^package/||; s|\.sh .*||; s|^.*/dnf .*|dnf|' "$CALLS" | paste -sd'|')"
check "the dependencies are those of the family of the table" "package/rpm/install-build-deps.sh fedora" "$(sed -n 1p "$CALLS")"
check "the short names are asked of the distribution's containers-common" 1 "$(grep -c 'dnf install -y --setopt=install_weak_deps=False containers-common' "$CALLS")"
check "the payload is built from the three trees, for the family, with the list the distribution ships" \
	"package/build-payload.sh $WORK/src/podman $WORK/src/netavark $WORK/src/aardvark $(sed -n 4p "$CALLS" | awk '{print $5}') fedora $WORK/shortnames-dir/000-shortnames.conf" "$(sed -n 4p "$CALLS")"
check "the rpm is built from that payload, for the id and the version, into the output directory" \
	"package/rpm/build-rpm.sh $(sed -n 4p "$CALLS" | awk '{print $5}') fc45 6.2.0+r12 $WORK/out" "$(sed -n 5p "$CALLS")"

check "the extras are built last, for the id, the revision, the verified sources and the output directory" "package/rpm/build-extras.sh fc45 12 $WORK/src/extras $WORK/out" "$(sed -n 6p "$CALLS")"
FAKE_FAIL=package/rpm/build-extras.sh run fc45 6.2.0+r12 "$WORK/out"; check "extras that cannot be built stop the build" 1 "$rc"
FAKE_FAIL=package/rpm/install-build-deps.sh run fc45 6.2.0+r12 "$WORK/out"; check "dependencies that cannot be installed stop the build, before the payload" "1 0" "$rc $(grep -c build-payload "$CALLS")"
FAKE_FAIL=package/rpm/check-replacement.sh run fc45 6.2.0+r12 "$WORK/out"; check "a package of the distribution that this one neither satisfies nor replaces stops the build before the payload" "1 0" "$rc $(grep -c build-payload "$CALLS")"
FAKE_FAIL=package/build-payload.sh run fc45 6.2.0+r12 "$WORK/out"; check "a payload that fails stops the build before the rpm" "1 0" "$rc $(grep -c build-rpm "$CALLS")"
FAKE_NO_COMMON=1 run fc45 6.2.0+r12 "$WORK/out"; check "a containers-common that cannot be installed stops the build, and says why" "1 1" "$rc $(says 'cannot install containers-common')"
FAKE_NO_SHORTNAMES=1 run fc45 6.2.0+r12 "$WORK/out"; check "a package with no short-name list stops the build" "1 1" "$rc $(says "ships no 000-shortnames.conf")"
run nope 6.2.0+r12 "$WORK/out"; check "an unknown distribution stops the build" 1 "$rc"
"$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
