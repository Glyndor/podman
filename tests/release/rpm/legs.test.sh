#!/usr/bin/env bash
#
# Tests for scripts/release/rpm/legs.sh: every leg of the table has to have reported an artifact that this run holds,
# and only then are the ids to download printed. The artifact of each is checked by check-upload.sh, whose refusals have
# their own suite; what is held here is that every leg is asked for, and that nothing else is accepted.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/release/rpm/legs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

SHA=0123456789abcdef0123456789abcdef01234567
H="$(printf 'a%.0s' $(seq 1 64))"
LEGS="$(bash "$HERE/scripts/release/rpm/names.sh" legs)"
# The report of every leg, its artifacts numbered from 101, and the list the run would give for them.
make() { # <prefix>: writes $WORK/legs.json and $WORK/list
	local id arch n=100
	: > "$WORK/list"
	printf '{' > "$WORK/legs.json"
	while read -r id arch; do
		n=$((n + 1))
		printf '"%s_%s":"%s %s podman.rpm=%s",' "$id" "$arch" "$n" "$H" "$H" >> "$WORK/legs.json"
		printf '%s-%s-%s\t%s\tfalse\t%s\tsha256:%s\n' "$1" "$id" "$arch" "$n" "$SHA" "$H" >> "$WORK/list"
	done <<< "$LEGS"
	sed -i 's/,$/}/' "$WORK/legs.json"
}
legs() { out="$(bash "$SCRIPT" "${1:-rpm}" "$SHA" "$(cat "$WORK/legs.json")" "$WORK/list" 2> "$WORK/err")"; rc=$?; err="$(cat "$WORK/err")"; }
errs() { printf '%s\n' "$err" | grep -c -F -- "$1"; }
refused() { check "$1" "1 empty 1" "$rc ${out:-empty} $(errs "$2")"; }
edit() { jq -c "$1" "$WORK/legs.json" > "$WORK/new" && mv "$WORK/new" "$WORK/legs.json"; }

make rpm; legs
check "every leg reported what the run holds: the ids, in the order of the legs" "0 $(seq -s, 101 114)" "$rc $out"
make rpmcheck; legs rpmcheck
check "the artifacts of a check have their own prefix" 0 "$rc"
make rpm; legs rpmcheck
refused "the artifacts of a release are not a check's" "is called rpm-fc45-x86_64, not rpmcheck-fc45-x86_64"
make rpm; legs deb
refused "another prefix is refused" "not 'deb-'"
make rpm; edit 'del(.el9_aarch64)'; legs
refused "a leg that reported nothing" "the build jobs reported"
make rpm; edit '. + {"fc43_x86_64": "1 a b"}'; legs
refused "an output that is no leg" "the build jobs reported"
make rpm; edit '.el9_aarch64 = ""'; legs
refused "a leg whose report is empty" "the leg el9_aarch64 reported no hash of its packages"
make rpm; edit '.el9_aarch64 = (.el9_aarch64 | split(" ")[:2] | join(" "))'; legs
refused "a leg that reported no hash" "the leg el9_aarch64 reported no hash of its packages"
make rpm; edit '.el9_aarch64 = 5'; legs
refused "a report that is not text" "reported something that is not text"
make rpm; printf '[]' > "$WORK/legs.json"; legs
refused "reports that are not an object" "is not a JSON object"
make rpm; printf 'not json' > "$WORK/legs.json"; legs
refused "reports that are not JSON" "is not a JSON object"
make rpm; edit '.leap161_x86_64 |= sub("^[0-9]+"; "999")'; legs
refused "a leg whose artifact the run does not list" "does not list exactly one artifact with the id 999"
make rpm; sed -i '/rpm-tumbleweed-aarch64/d' "$WORK/list"; legs
refused "a leg whose artifact is gone from the run" "does not list exactly one artifact"
out="$(GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" rpm "$SHA" '{}' "$WORK/list" 2> "$WORK/err")"; rc=$?; err="$(cat "$WORK/err")"
refused "legs that cannot be read" "the legs of distros.txt cannot be read"
bash "$SCRIPT" rpm "$SHA" > /dev/null 2>&1; check "too few arguments is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
