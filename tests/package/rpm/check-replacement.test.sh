#!/usr/bin/env bash
#
# Tests for scripts/package/rpm/check-replacement.sh with a dnf that answers from the case:
# what the distribution has that requires podman is satisfied or replaced, or the build of
# that distribution stops and names what is not.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/rpm/check-replacement.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin"
# dnf repoquery --whatrequires podman lists $REQUIRERS; --requires <pkg> prints the lines in $WORK/req-<pkg>.
cat > "$WORK/bin/dnf" <<'DNF'
#!/bin/sh
[ "$1" = repoquery ] || exit 1
case "$2" in
	--whatrequires) [ -z "$FAIL_WHATREQUIRES" ] || exit 1; for p in $REQUIRERS; do echo "$p"; done ;;
	--requires) [ -z "$FAIL_REQUIRES" ] || exit 1; cat "$REQ_DIR/req-$3" 2> /dev/null ;;
esac
DNF
printf '#!/bin/sh\n[ -z "$FAKE_GREP_FAILS" ] || [ "$1" != -E ] || exit 2\nexec %s "$@"\n' "$(command -v grep)" > "$WORK/bin/grep"
chmod +x "$WORK/bin/dnf" "$WORK/bin/grep"
printf 'fc45|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|\nel9|rpm|el|x86_64|6|3|5|podman|0^20260716|\namzn2023|rpm|amzn|x86_64|0|2|5|upstream|0^20260716|\n' > "$WORK/table"
export REQ_DIR="$WORK" GLYNDOR_DISTROS_FILE="$WORK/table"
PATH="$WORK/bin:$PATH"
run() { out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

REQUIRERS="podman-docker podmansh podman-machine podman-tests" run fc45
check "the packages that are ours or are obsoleted are not asked about" 0 "$rc"
printf 'podman = 5:6.2.0-1.fc45\n' > "$WORK/req-cockpit-podman"
REQUIRERS="podman-docker cockpit-podman" run fc45
check "another package that requires an exact version stops the build, and is named" "1 1" "$rc $(says 'cockpit-podman requires podman exactly (5:6.2.0-1.fc45)')"
printf 'podman >= 2:4.8.1-1\n' > "$WORK/req-container-tools"
REQUIRERS="podman-docker container-tools" run el9
check "a requirement of a lower or equal epoch is satisfied" 0 "$rc"
printf 'podman >= 7:6.1.0-1\n' > "$WORK/req-container-tools"
REQUIRERS="podman-docker container-tools" run el9
check "a requirement of an epoch above ours stops the build" "1 1" "$rc $(says 'requires podman at epoch 7, above the 6 of this package')"
printf 'podman\n' > "$WORK/req-plain"
REQUIRERS="podman-docker plain" run fc45
check "a plain requirement is satisfied" 0 "$rc"
printf 'libc.so.6()(64bit)\n' > "$WORK/req-other"
REQUIRERS="podman-docker other" run fc45
check "a requirement of something else is not read" 0 "$rc"
REQUIRERS="" run fc45
check "an empty answer where podman-docker is known to exist is refused" "1 1" "$rc $(says 'do not list podman-docker')"
REQUIRERS="" run amzn2023
check "an empty answer where the distribution has no podman is the answer" 0 "$rc"
FAIL_WHATREQUIRES=1 REQUIRERS="podman-docker" run fc45
check "a dnf that cannot say what requires podman stops the build, and does not pass" "1 1" "$rc $(says 'cannot ask the repositories what requires podman')"
FAIL_WHATREQUIRES=1 REQUIRERS="" run amzn2023
check "and neither does one that fails where the answer may be empty" 1 "$rc"
printf 'podman >= 2:1-1\n' > "$WORK/req-someone"
FAIL_REQUIRES=1 REQUIRERS="podman-docker someone" run fc45
check "a dnf that cannot say what a package requires stops the build" "1 1" "$rc $(says 'cannot ask the repositories what someone requires')"
FAKE_GREP_FAILS=1 REQUIRERS="podman-docker someone" run fc45
check "a grep that fails on what a package requires is not read as no requirement" "1 1" "$rc $(says 'cannot read what someone requires')"
"$SCRIPT" > /dev/null 2>&1; check "no id is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
