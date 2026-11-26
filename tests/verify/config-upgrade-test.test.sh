#!/usr/bin/env bash
#
# Tests for scripts/verify/config-upgrade-test.sh as far as a stand-in reaches: its argument contract. It
# installs the published package and then the new one with apt, as root, in a clean container of a release, and
# nothing here can be that; its real run is the job config-upgrade of .github/workflows/release.yml, on a runner of its own
# before anything is signed, with the published package verified against the release key first. The
# maintainer scripts it exercises are run against a root of their own in tests/build/build-deb.test.sh.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/config-upgrade-test.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

bash "$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 2 "$?"
bash "$SCRIPT" "$WORK/old.deb" > /dev/null 2>&1; check "one argument is refused" 2 "$?"
bash "$SCRIPT" "$WORK/old.deb" "$WORK/new.deb" > /dev/null 2>&1; check "packages that are not there are a usage error" 2 "$?"
for case in unedited edited reinstall deleted; do
	check "the case '$case' is run" 1 "$([ "$(grep -c "^check \"$case" "$SCRIPT")" -ge 1 ] && echo 1 || echo 0)"
done
check "the case of a link in the place of the file is run, with one that points at a file and one that points nowhere" "1 1" \
	"$([ "$(grep -c 'check "linked to' "$SCRIPT")" -ge 1 ] && echo 1 || echo 0) $(grep -c 'for linked in "\$central" /nonexistent-policy.json' "$SCRIPT")"
check "no force option and no answer is given to dpkg: the runs of the new package have stdin closed, and none forces a conffile" "1 0" \
	"$([ "$(grep -c 'apt-get install -y "$new" < /dev/null' "$SCRIPT")" -ge 1 ] && echo 1 || echo 0) $(grep '"$new"' "$SCRIPT" | grep -c -e '--force-conf' -e 'DEBCONF_NONINTERACTIVE_SEEN')"
check "the constant of the version the file stopped being shipped is the one of build-deb.sh" "$(sed -n 's/^config_free_since="\(.*\)"/\1/p' "$HERE/scripts/build/build-deb.sh")" \
	"$(sed -n 's/^config_free_since=//p' "$SCRIPT")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
