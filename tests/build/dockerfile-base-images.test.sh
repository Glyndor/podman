#!/usr/bin/env bash
#
# Tests that every image scripts/build/Dockerfile starts from is pinned by digest.
#
# build-deb.sh evaluates what a tool of the build image prints, and says it may because
# the image is pinned by digest; the smoke tests install the package into the other
# three. A tag alone is whatever the registry answers that day, so the digest is what
# makes the build's input a known one. Dependabot moves the digests; nothing required
# them, and taking one out left every suite green.
#
# A stage may also start from an earlier stage of the same file, by its name.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <Dockerfile>: one line per FROM that is neither an earlier stage nor an
# image with a release tag and a sha256 digest. Prints "no FROM" for a file without one.
violations() {
	python3 - "$1" <<'PY'
import re, sys
stages, seen = set(), 0
for number, line in enumerate(open(sys.argv[1]), 1):
    words = line.split()
    if not words or words[0].upper() != "FROM":
        continue
    seen += 1
    args = [w for w in words[1:] if not w.startswith("--")]
    image = args[0] if args else ""
    name = args[2] if len(args) >= 3 and args[1].upper() == "AS" else ""
    if image in stages:
        pass
    elif not re.fullmatch(r"[a-z0-9./-]+:[0-9][A-Za-z0-9._-]*@sha256:[0-9a-f]{64}", image):
        print(f"line {number}: {image or '(nothing)'} is not a release tag pinned by a sha256 digest")
    if name:
        stages.add(name)
if not seen:
    print("no FROM")
PY
}

check "every image the build's Dockerfile starts from is pinned by digest" "" "$(violations "$HERE/scripts/build/Dockerfile")"
check "and it starts from the five images the build, the smoke tests and the refusal tests use" "5" \
	"$(grep -c -E '^FROM [a-z0-9./-]+:[0-9][A-Za-z0-9._-]*@sha256:[0-9a-f]{64} AS ' "$HERE/scripts/build/Dockerfile")"

# The build runs on amd64 and on arm64 from this one Dockerfile, so each image it starts from is pinned by the
# digest of an INDEX that has a linux/amd64 and a linux/arm64 image: the digest of one architecture's manifest
# makes the other runner try to execute the wrong binaries ("exec format error"). The index is read from the
# registry, with docker or podman, whichever the machine has; with neither the check says so and fails.
platforms() { # <name:tag@digest>: the linux platforms of the index, or why it could not be read
	local ref="$1" name digest raw
	name="${ref%%:*}"; digest="${ref##*@}"
	case "$name" in */*) ;; *) name="docker.io/library/$name" ;; esac
	if command -v docker > /dev/null 2>&1 && raw="$(docker buildx imagetools inspect --raw "$name@$digest" 2> /dev/null)"; then :
	elif command -v podman > /dev/null 2>&1 && raw="$(podman manifest inspect "docker://$name@$digest" 2> /dev/null)"; then :
	else echo "cannot read the manifest of $ref with docker or podman"; return; fi
	printf '%s' "$raw" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "manifests" not in d:
    print("not an index")
else:
    print(" ".join(sorted({m["platform"]["architecture"] for m in d["manifests"] if m.get("platform", {}).get("os") == "linux"} & {"amd64", "arm64"})))
'
}
for ref in $(sed -n 's/^FROM \([^ ]*@sha256:[0-9a-f]*\) .*/\1/p' "$HERE/scripts/build/Dockerfile"); do
	check "$ref is the digest of an index with an amd64 and an arm64 image" "amd64 arm64" "$(platforms "$ref")"
done

D="$WORK/Dockerfile"
ok='FROM debian:13@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS base'
printf '%s\nRUN true\nFROM base AS build\nFROM --platform=linux/arm64 base AS other\n' "$ok" > "$D"
check "a pinned image, a stage built on it and a platform flag pass" "" "$(violations "$D")"

printf 'FROM debian:13 AS base\n' > "$D"
check "a tag with no digest is named" "line 1: debian:13 is not a release tag pinned by a sha256 digest" "$(violations "$D")"
printf 'FROM debian:13@sha256:9c6e3814 AS base\n' > "$D"
check "a digest that is not 64 hex characters is named" "line 1: debian:13@sha256:9c6e3814 is not a release tag pinned by a sha256 digest" "$(violations "$D")"
printf 'FROM debian@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS base\n' > "$D"
check "a digest with no release beside it is named" "1" "$(violations "$D" | grep -c 'is not a release tag pinned')"
printf 'FROM debian:latest@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS base\n' > "$D"
check "a tag that is not a release is named" "1" "$(violations "$D" | grep -c 'is not a release tag pinned')"
printf '%s\nFROM build AS later\n' "$ok" > "$D"
check "a stage that starts from a name no earlier stage has is named" "line 2: build is not a release tag pinned by a sha256 digest" "$(violations "$D")"
printf '%s\nFROM ubuntu:24.04 AS second\n' "$ok" > "$D"
check "the second image is held as the first" "line 2: ubuntu:24.04 is not a release tag pinned by a sha256 digest" "$(violations "$D")"
printf 'RUN true\n' > "$D"
check "a file with no FROM is not a pass" "no FROM" "$(violations "$D")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
