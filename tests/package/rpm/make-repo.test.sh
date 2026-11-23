#!/usr/bin/env bash
#
# Tests for scripts/package/rpm/make-repo.sh, which makes the metadata of the repository the proof installs from,
# in the build container, so that an image without createrepo_c (Red Hat's UBI) reads the same repository. dnf,
# zypper and createrepo_c are stand-ins that write down what they were asked and make what the real one makes.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/rpm/make-repo.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

bin="$WORK/bin"; mkdir -p "$bin" "$WORK/suse"
printf '#!/bin/sh\necho "dnf $*" >> "%s/calls"\n[ -z "$FAKE_INSTALL_FAILS" ]\n' "$WORK" > "$bin/dnf"
printf '#!/bin/sh\necho "zypper $*" >> "%s/calls"\n[ -z "$FAKE_INSTALL_FAILS" ]\n' "$WORK" > "$WORK/suse/zypper"
chmod +x "$bin/dnf" "$WORK/suse/zypper"
cat > "$bin/createrepo_c" <<'CR'
#!/bin/sh
echo "createrepo_c $*" >> "$WORK_CALLS"
[ -z "$FAKE_NO_METADATA" ] || exit 0
while [ "$#" -gt 1 ]; do
	[ "$1" = --outputdir ] && { mkdir -p "$2/repodata"; : > "$2/repodata/repomd.xml"; }
	shift
done
CR
chmod +x "$bin/createrepo_c"
# A PATH of the stand-ins and the plain tools, without a zypper of this machine unless the case wants one.
mkdir -p "$WORK/plain"
# no find and no wc: the build image of Amazon Linux 2023 has neither findutils nor, for this script, any need of them
for t in bash sh cat ls mkdir rm tr; do ln -sf "$(command -v "$t")" "$WORK/plain/$t"; done
mkdir -p "$WORK/in" "$WORK/out"; : > "$WORK/in/podman-1.rpm"

run() { # <extra env...> -> exit status, calls in $WORK/calls
	: > "$WORK/calls"; rm -rf "$WORK/out/repodata"
	env WORK_CALLS="$WORK/calls" "$@" bash "$SCRIPT" "$WORK/in" "$WORK/out" > "$WORK/stdout" 2> "$WORK/stderr"
}
dnf_path="$bin:$WORK/plain"
run PATH="$dnf_path"; rc=$?
check "on a distribution with dnf it installs createrepo_c with dnf, makes the metadata and says so" "0 dnf install -y createrepo_c|createrepo_c --outputdir $WORK/out $WORK/in|" \
	"$rc $(paste -sd'|' "$WORK/calls")|$(grep -c 'repository metadata of 1 packages' "$WORK/stdout" | sed 's/1//;s/0/x/')"
check "the metadata is where the proof reads it" 1 "$([ -f "$WORK/out/repodata/repomd.xml" ] && echo 1 || echo 0)"
run PATH="$dnf_path:$WORK/suse"; rc=$?
check "on a distribution with zypper it installs the tool with zypper, not dnf" "0 1 0" "$rc $(grep -c '^zypper --non-interactive install --no-recommends createrepo_c' "$WORK/calls") $(grep -c '^dnf ' "$WORK/calls")"
run PATH="$dnf_path" FAKE_INSTALL_FAILS=1; rc=$?
check "a tool that cannot be installed stops it, and createrepo_c is not run" "1 0" "$rc $(grep -c '^createrepo_c' "$WORK/calls")"
run PATH="$dnf_path" FAKE_NO_METADATA=1; rc=$?
check "a createrepo_c that writes no repomd.xml is an error, and says what is missing" "1 1" "$rc $(grep -c 'wrote no repodata/repomd.xml' "$WORK/stderr")"
mkdir -p "$WORK/empty"
: > "$WORK/calls"; PATH="$dnf_path" WORK_CALLS="$WORK/calls" bash "$SCRIPT" "$WORK/empty" "$WORK/out" > /dev/null 2> "$WORK/stderr"; rc=$?
check "a directory with no rpm is refused before anything is installed" "1 1 0" "$rc $(grep -c 'no .rpm file in' "$WORK/stderr") $(wc -l < "$WORK/calls" | tr -d ' ')"
PATH="$dnf_path" bash "$SCRIPT" "$WORK/nowhere" "$WORK/out" > /dev/null 2> "$WORK/stderr"; rc=$?
check "a directory of packages that is not there is refused, and named" "1 1" "$rc $(grep -c "^$WORK/nowhere is not a directory" "$WORK/stderr")"
PATH="$dnf_path" bash "$SCRIPT" "$WORK/in" "$WORK/nowhere" > /dev/null 2> "$WORK/stderr"; rc=$?
check "an output directory that is not there is refused, and named" "1 1" "$rc $(grep -c "^$WORK/nowhere is not a directory" "$WORK/stderr")"
PATH="$dnf_path" bash "$SCRIPT" > /dev/null 2> "$WORK/stderr"; rc=$?
check "no argument is a usage error" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
