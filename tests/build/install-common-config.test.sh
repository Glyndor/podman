#!/usr/bin/env bash
#
# Tests for scripts/build/install-common-config.sh: the containers-common files of
# the release land where the spec puts them, and a missing piece stops the build.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/build/install-common-config.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SMOKE="$HERE/scripts/verify/smoke-test.sh"
STATE="$HERE/scripts/verify/package-state.sh"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir -p "$WORK/src" "$WORK/mods/common/pkg/config" "$WORK/mods/common/pkg/seccomp" "$WORK/mods/common/rpm" "$WORK/mods/image" "$WORK/mods/storage"
printf 'module x\nrequire (\n\tgo.podman.io/common v0.70.0\n\tgo.podman.io/image/v5 v5.42.1\n\tgo.podman.io/storage v1.65.1\n)\n' > "$WORK/src/go.mod"
echo '[containers]' > "$WORK/mods/common/pkg/config/containers.conf"
echo '{"syscalls":[{"names":["futex_waitv"]}]}' > "$WORK/mods/common/pkg/seccomp/seccomp.json"
echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$WORK/mods/common/rpm/policy.json"
echo 'unqualified-search-registries = []' > "$WORK/mods/image/registries.conf"
echo 'default-docker:' > "$WORK/mods/image/default.yaml"
echo '[storage]' > "$WORK/mods/storage/storage.conf"
echo '[aliases]' > "$WORK/short.conf"
export GLYNDOR_MODULES_DIR="$WORK/mods"

out="$("$SCRIPT" "$WORK/src" "$WORK/stage" "$WORK/short.conf" 2>/dev/null)"; rc=$?
check "succeeds" 0 "$rc"
check "prints the version of common the tag pins" 0.70.0 "$out"
for f in containers.conf seccomp.json registries.conf registries.d/default.yaml registries.conf.d/000-shortnames.conf; do
	check "installs $f under /usr/share/containers" 1 "$([ -s "$WORK/stage/usr/share/containers/$f" ] && echo 1 || echo 0)"
done
check "installs policy.json under /etc/containers, where buildah and skopeo read it" 1 "$([ -s "$WORK/stage/etc/containers/policy.json" ] && echo 1 || echo 0)"
check "a rootless user gets its own runroot even if the system storage.conf sets one" 1 \
	"$(grep -c 'runroot = "/run/user/$UID/containers"' "$WORK/stage/usr/share/containers/storage.rootless.conf.d/10-glyndor-rootless-paths.conf")"
check "and its own graphroot" 1 \
	"$(grep -c 'graphroot = "$HOME/.local/share/containers/storage"' "$WORK/stage/usr/share/containers/storage.rootless.conf.d/10-glyndor-rootless-paths.conf")"
check "storage.conf stays with the package that owns it" 0 "$([ -e "$WORK/stage/usr/share/containers/storage.conf" ] && echo 1 || echo 0)"
check "the seccomp profile is the module's, not another" 1 "$(grep -c futex_waitv "$WORK/stage/usr/share/containers/seccomp.json")"
check "creates the directories the spec owns" 1 "$([ -d "$WORK/stage/etc/containers/oci/hooks.d" ] && echo 1 || echo 0)"

# What the smoke test asks of the installed package under these two folders has to be
# what this script puts in the stage: a path mistyped in either list is otherwise found
# by the build, after twelve minutes and two architectures. The paths are read from the
# smoke test and the script it calls, comments left out, and a list that came out too
# short is a failure of the reading and not an empty set that passes.
required="$( {
	grep -v '^[[:space:]]*#' "$SMOKE" | sed -n 's/^for f in \(registries\.conf [^;]*\); do$/\1/p' | tr ' ' '\n' | sed 's#^#/usr/share/containers/#'
	grep -v '^[[:space:]]*#' "$SMOKE" "$STATE" | grep -o '/\(etc\|usr/share\)/containers/[A-Za-z0-9._/-]*' | grep -v '/$'
} | sort -u)"
check "the smoke test names at least the five files this script installs" 1 "$([ "$(printf '%s\n' "$required" | grep -c .)" -ge 5 ] && echo 1 || echo 0)"
missing=""
while IFS= read -r path; do
	[ -s "$WORK/stage$path" ] || missing="$missing $path"
done <<< "$required"
check "every file the smoke test requires is installed by this script" "" "${missing# }"

rm "$WORK/mods/common/rpm/policy.json"
"$SCRIPT" "$WORK/src" "$WORK/stage2" "$WORK/short.conf" >/dev/null 2>&1; check "a module without policy.json is refused" 1 "$?"
echo '{}' > "$WORK/mods/common/rpm/policy.json"
"$SCRIPT" "$WORK/src" "$WORK/stage3" "$WORK/nothing.conf" >/dev/null 2>&1; check "a missing short-name list is refused" 1 "$?"
printf 'module x\n' > "$WORK/src/go.mod"
"$SCRIPT" "$WORK/src" "$WORK/stage4" "$WORK/short.conf" >/dev/null 2>&1; check "a go.mod without the modules is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
