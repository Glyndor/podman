#!/usr/bin/env bash
#
# The tags of the images the native packages are built in. Dependabot moved the Amazon Linux image from the floating tag 2023 to
# 2023.0.20230614.0, an image of three years before, because it reads the tag of every build of the registry as a newer version
# of "2023" (podman#105). So no image of scripts/package/images is pinned by a dated tag (a build date in the tag is always older
# than the one the registry has published since), Amazon Linux is pinned by 2023 and its digest, and .github/dependabot.yml
# ignores the versions above 2023 for it, with the reason written there. Read from the files, with copies that break each.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# dated <images dir>: the images pinned by a tag that carries a date (eight digits, as YYYYMMDD), one per line.
dated() {
	for f in "$1"/*/Dockerfile; do
		tag="$(sed -n 's/^FROM [^ :]*:\([^ @]*\).*/\1/p' "$f" | head -n 1)"
		if printf '%s\n' "$tag" | grep -q -E '(^|[._-])[0-9]{8}($|[._-])|[0-9]{4}\.[0-9]+\.[0-9]{8}'; then echo "$(basename "$(dirname "$f")"): $tag"; fi
	done
}
check "no image is pinned by a tag that carries a date" "" "$(dated "$HERE/scripts/package/images")"
check "Amazon Linux is pinned by the floating tag 2023 and the digest of its index" 1 \
	"$(grep -c -E '^FROM public\.ecr\.aws/amazonlinux/amazonlinux:2023@sha256:[0-9a-f]{64}$' "$HERE/scripts/package/images/amzn2023/Dockerfile")"

# dependabot <file>: what the images' docker entry ignores for Amazon Linux, as "versions=..."
ignored() {
	python3 - "$1" 2>&1 <<'PY' || echo "rule failed"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
for u in cfg["updates"]:
    if u["package-ecosystem"] == "docker" and any("package/images" in d for d in u.get("directories", [])):
        for i in u.get("ignore", []):
            if i.get("dependency-name") == "amazonlinux/amazonlinux":
                print("versions=" + ",".join(i.get("versions", [])))
PY
}
check "dependabot ignores the versions above 2023 for Amazon Linux" "versions=>2023" "$(ignored "$HERE/.github/dependabot.yml")"
check "and says why, in the file, naming the pull request that moved it back" 1 "$(grep -c 'podman#105' "$HERE/.github/dependabot.yml")"

# The rule on copies that break it.
mkdir -p "$WORK/images/x" "$WORK/images/y"
printf 'FROM public.ecr.aws/amazonlinux/amazonlinux:2023.0.20230614.0@sha256:%064d\n' 0 > "$WORK/images/x/Dockerfile"
printf 'FROM quay.io/almalinuxorg/almalinux:10@sha256:%064d\n' 0 > "$WORK/images/y/Dockerfile"
check "an image pinned by a tag with a date is named" "x: 2023.0.20230614.0" "$(dated "$WORK/images")"
printf 'FROM registry.example/z:9.3-20260101@sha256:%064d\n' 0 > "$WORK/images/x/Dockerfile"
check "so is a date written another way" "x: 9.3-20260101" "$(dated "$WORK/images")"
sed '/versions: \[">2023"\]/d' "$HERE/.github/dependabot.yml" > "$WORK/dependabot.yml"
check "a dependabot.yml whose Amazon Linux entry no longer lists the versions is told by the empty list" "versions=" "$(ignored "$WORK/dependabot.yml")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
