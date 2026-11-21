#!/usr/bin/env bash
#
# Tests for scripts/upstream/plan-release.sh: when a release is needed and how
# it is named, including a bump of a component under an unchanged Podman.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/plan-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

fresh="$WORK/fresh"
printf 'podman v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\n' > "$fresh"
: > "$WORK/none"

check "first ever release" "build=true tag=v6.2.0" \
	"$("$SCRIPT" "$fresh" "$WORK/none" "$WORK/none" | paste -sd' ')"

printf 'aardvark-dns v2.1.0\npodman v6.2.0\nnetavark v2.1.0\n' > "$WORK/same"
printf 'v6.2.0\n' > "$WORK/t1"
check "nothing changed, in any order" "build=false" "$("$SCRIPT" "$fresh" "$WORK/same" "$WORK/t1")"

printf 'podman v6.2.0\nnetavark v2.0.0\naardvark-dns v2.1.0\n' > "$WORK/old"
# The bare tag is the first build of a version and counts as revision 1 (the `:-1` in
# plan-release.sh), so the second build is +r2 and no release is called +r1. Releases
# from v6.2.0 to v6.2.0+r10 are published under that numbering, so it stays.
check "a component changed under the same podman: the second build is +r2" "build=true tag=v6.2.0+r2" \
	"$("$SCRIPT" "$fresh" "$WORK/old" "$WORK/t1" | paste -sd' ')"

printf 'v6.2.0\nv6.2.0+r2\nv6.1.4\n' > "$WORK/t2"
check "the counter keeps climbing" "build=true tag=v6.2.0+r3" \
	"$("$SCRIPT" "$fresh" "$WORK/old" "$WORK/t2" | paste -sd' ')"

printf 'v6.2.0\nv6.2.0+r3\n' > "$WORK/tgap"
check "a missing revision does not make the next name collide" "build=true tag=v6.2.0+r4" \
	"$("$SCRIPT" "$fresh" "$WORK/old" "$WORK/tgap" | paste -sd' ')"

{ echo v6.2.0; for i in $(seq 2 250); do echo "v6.2.0+r$i"; done; } > "$WORK/tmany"
check "past two hundred revisions it still picks a free name" "build=true tag=v6.2.0+r251" \
	"$("$SCRIPT" "$fresh" "$WORK/old" "$WORK/tmany" | paste -sd' ')"

printf 'v6.2.0+r2\n' > "$WORK/tonlyr"
check "a revision without its base tag still counts" "build=true tag=v6.2.0+r3" \
	"$("$SCRIPT" "$fresh" "$WORK/old" "$WORK/tonlyr" | paste -sd' ')"

printf 'podman v6.1.4\nnetavark v2.1.0\naardvark-dns v2.1.0\n' > "$WORK/older"
printf 'v6.1.4\nv6.1.4+r2\n' > "$WORK/t3"
check "a new podman starts at its own version" "build=true tag=v6.2.0" \
	"$("$SCRIPT" "$fresh" "$WORK/older" "$WORK/t3" | paste -sd' ' | sed 's/^build=true //; s/^/build=true /')"

"$SCRIPT" "$fresh" "$WORK/none" "$WORK/t1" >/dev/null 2>&1
check "tags without readable released components fails instead of building" 1 "$?"

# components.txt is a record of its release as well as the input of the comparison, so it
# may grow a line the plan knows nothing about. Compared whole, such a line differs on
# every run and the scheduler publishes a +rN every six hours for ever; the cases below
# change what is in the file around the three lines of $fresh, and each refusal to
# build is paired with a case that builds.
printf 'podman v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\nsignature mldsa65\n' > "$WORK/extra"
check "a line that is not a component does not make the plan build" "build=false" "$("$SCRIPT" "$fresh" "$WORK/extra" "$WORK/t1")"
printf 'signature mldsa65\npodman v6.2.0\ndate 2026-11-21\nnetavark v2.1.0\naardvark-dns v2.1.0\n\n' > "$WORK/extra2"
check "however many there are, wherever they sit, and with blank lines" "build=false" "$("$SCRIPT" "$fresh" "$WORK/extra2" "$WORK/t1")"
printf 'podman v6.2.0\nnetavark v2.0.0\naardvark-dns v2.1.0\nsignature mldsa65\n' > "$WORK/extra-old"
check "an extra line does not hide a component that changed" "build=true tag=v6.2.0+r2" \
	"$("$SCRIPT" "$fresh" "$WORK/extra-old" "$WORK/t1" | paste -sd' ')"
printf 'podman v6.2.0\nnetavark v2.1.0\nsignature mldsa65\n' > "$WORK/extra-missing"
check "an extra line does not stand in for a component the release does not list" "build=true tag=v6.2.0+r2" \
	"$("$SCRIPT" "$fresh" "$WORK/extra-missing" "$WORK/t1" | paste -sd' ')"
printf 'signature mldsa65\n' > "$WORK/only-extra"
check "a release that lists no component at all builds" "build=true tag=v6.2.0+r2" \
	"$("$SCRIPT" "$fresh" "$WORK/only-extra" "$WORK/t1" | paste -sd' ')"
printf 'podman v6.2.0\npodman-extra v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\n' > "$WORK/lookalike"
check "a line whose name only starts like a component is not that component" "build=false" "$("$SCRIPT" "$fresh" "$WORK/lookalike" "$WORK/t1")"
printf 'podman-extra v6.2.0\nnetavark v2.1.0\naardvark-dns v2.1.0\n' > "$WORK/lookalike-only"
check "and does not stand in for the component it looks like" "build=true tag=v6.2.0+r2" \
	"$("$SCRIPT" "$fresh" "$WORK/lookalike-only" "$WORK/t1" | paste -sd' ')"
printf 'podman v6.2.0\npodman v6.1.0\nnetavark v2.1.0\naardvark-dns v2.1.0\n' > "$WORK/twice"
check "a component listed with two different tags builds" "build=true tag=v6.2.0+r2" \
	"$("$SCRIPT" "$fresh" "$WORK/twice" "$WORK/t1" | paste -sd' ')"

# The same, end to end through read-released.sh: the next run reads back the release the
# last one published, extra line included, and must find nothing to do.
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"release list") echo v6.2.0+r2 ;;
	"release download")
		while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
		cp "$RELEASE_COMPONENTS" "$out" ;;
esac
GH
chmod +x "$WORK/bin/gh"
printf 'v6.2.0\nv6.2.0+r2\n' > "$WORK/t-r2"
RELEASE_COMPONENTS="$WORK/extra" PATH="$WORK/bin:$PATH" bash "$HERE/scripts/upstream/read-released.sh" "$WORK/read" >/dev/null 2>&1
check "a release read back with an extra line is not published again" "build=false" "$("$SCRIPT" "$fresh" "$WORK/read" "$WORK/t-r2")"
RELEASE_COMPONENTS="$WORK/extra-old" PATH="$WORK/bin:$PATH" bash "$HERE/scripts/upstream/read-released.sh" "$WORK/read" >/dev/null 2>&1
check "and one read back with a stale component is, as the next revision" "build=true tag=v6.2.0+r3" \
	"$("$SCRIPT" "$fresh" "$WORK/read" "$WORK/t-r2" | paste -sd' ')"


printf 'netavark v2.1.0\n' > "$WORK/nopodman"
"$SCRIPT" "$WORK/nopodman" "$WORK/none" "$WORK/none" >/dev/null 2>&1; check "no podman line fails" 1 "$?"

# An upstream that could not be read leaves <fresh> empty. Against a release that
# lists only lines that are not components it would compare equal, so the refusal
# has to come before the comparison.
: > "$WORK/empty"; printf 'signature ed25519\n' > "$WORK/notes-only"
out="$("$SCRIPT" "$WORK/empty" "$WORK/notes-only" "$WORK/t1" 2>&1)"; rc=$?
check "an empty fresh list fails instead of planning nothing" 1 "$rc"
check "and the refusal is the missing podman tag" 1 "$(printf '%s' "$out" | grep -c 'no podman tag')"
out="$("$SCRIPT" "$WORK/empty" "$WORK/same" "$WORK/t1" 2>&1)"; rc=$?
check "and so does an empty fresh list against a full release" "1 0" "$rc $(printf '%s' "$out" | grep -c 'build=')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
