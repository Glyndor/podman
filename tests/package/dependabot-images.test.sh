#!/usr/bin/env bash
#
# The images the native packages are built and proved in are pinned by digest when their registry keeps the digests it
# replaces (AlmaLinux, Rocky, UBI), and Dependabot moves those pins: every directory of scripts/package/images has to be
# read by the docker ecosystem of .github/dependabot.yml, and every pull request it opens has to land in the
# one group of image bumps, which is what keeps the five or six digests that change on a day from becoming five or six
# pull requests that each have to be rebased behind the other.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# uncovered <dependabot.yml> <images dir>: the image directories no docker entry reads, one per line, then the groups
# of that entry as "group: patterns".
report() {
	python3 - "$1" "$2" 2>&1 <<'PY' || echo "rule failed"
import fnmatch, os, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
root = sys.argv[2]
entries = [u for u in cfg["updates"] if u["package-ecosystem"] == "docker" and any("package/images" in d for d in u.get("directories", []))]
if len(entries) != 1:
    print(f"{len(entries)} docker entries read the images, expected 1")
    sys.exit()
entry = entries[0]
for d in sorted(os.listdir(root)):
    if os.path.isdir(os.path.join(root, d)) and not any(fnmatch.fnmatch(f"/scripts/package/images/{d}", g) for g in entry["directories"]):
        print(f"not read: {d}")
for name, g in (entry.get("groups") or {}).items():
    print(f"group {name}: {','.join(g.get('patterns', []))}")
if "groups" not in entry:
    print("no groups")
PY
}
out="$(report "$HERE/.github/dependabot.yml" "$HERE/scripts/package/images")"
check "every directory of scripts/package/images is read by Dependabot" "" "$(printf '%s\n' "$out" | grep -e '^not read' -e 'rule failed' -e 'docker entries')"
check "their updates come in one group that takes every image" "group package-images: *" "$(printf '%s\n' "$out" | grep '^group')"
check "openSUSE Tumbleweed has an image directory among them" 1 "$([ -f "$HERE/scripts/package/images/tumbleweed/Dockerfile" ] && echo 1 || echo 0)"
check "and its image is the rolling tag with no digest, which no pin could follow, and the rows that keep their digests are the ones Dependabot moves" "1 3" \
	"$(grep -c -E '^FROM registry.opensuse.org/opensuse/tumbleweed:latest$' "$HERE/scripts/package/images/tumbleweed/Dockerfile") $(grep -l -E '^FROM [a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' "$HERE"/scripts/package/images/*/Dockerfile | wc -l | tr -d ' ')"

# The same rule on a copy that breaks it: an image no entry reads, and a configuration with no group.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/images/fc45" "$WORK/images/newone"
cat > "$WORK/dependabot.yml" <<'YML'
version: 2
updates:
  - package-ecosystem: "docker"
    directories:
      - "/scripts/package/images/fc*"
YML
out="$(report "$WORK/dependabot.yml" "$WORK/images")"
check "an image directory no entry reads is named" "not read: newone" "$(printf '%s\n' "$out" | grep '^not read')"
check "an entry with no group is said to have none" "no groups" "$(printf '%s\n' "$out" | grep '^no groups')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
