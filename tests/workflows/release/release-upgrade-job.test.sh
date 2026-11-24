#!/usr/bin/env bash
#
# Tests for the job of .github/workflows/release.yml that upgrades the published package to the new one: it runs on a
# runner of its own, when there is something to build and only from main, verifies the package it downloaded against the
# release key before any container starts, runs no privileged container, mounts the new package read only, and takes no
# pre-release as the one to upgrade from. Its step that fetches and verifies is run with a fake gh and python.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

# --- the upgrade test of the published package ------------------------------------
# It runs a package that was published before, so it has a machine of its own, runs when there is a build and
# the branch is main, verifies what it downloaded against the release key before a container starts, installs
# nothing privileged, and only publish waits for it.
check "the upgrade test runs when there is something to build, and only from main" "github.ref == 'refs/heads/main' && needs.plan.outputs.build == 'true'" "$(gate release.yml config-upgrade if)"
check "it waits for the plan and the build, and holds nothing but read" "build-amd64,build-arm64,plan" "$(gate release.yml config-upgrade needs)"
cu="$WORK/config-upgrade.yml"
python3 - "$HERE/.github/workflows/release.yml" > "$cu" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["config-upgrade"]
for step in job["steps"]:
    print("### " + step.get("name", step.get("uses", "")))
    print(step.get("run", ""))
PY
check "no container of the upgrade test is privileged" 0 "$(grep -c -e '--privileged' "$cu")"
check "it excludes drafts and pre-releases when it picks the published release" 1 "$(grep -c -e 'gh release list --exclude-drafts --exclude-pre-releases' "$cu")"
check "the verification of the published package comes before any docker command" 1 \
	"$(awk '/verify-sig.py/{v=NR} /docker (build|run)/{if(!d)d=NR} END{print (v && d && v<d) ? 1 : 0}' "$cu")"
check "the second signature is required when the anchor holds a key" 1 "$(grep -c -e '--require-mldsa' "$cu")"
check "the new package is mounted read only" 1 "$(grep -c -e '/new:/new:ro' "$cu")"

# The step that fetches the published package and verifies it, run under bash -e -o pipefail with a gh that lists
# a tag and downloads empty files and a python3 whose venv verifies or refuses as told.
F="$WORK/fetch"
if step release.yml config-upgrade "name=Fetch the newest published release and verify it against the release key" "$F"; then
	mkdir -p "$F/bin"
	cat > "$F/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$2" = list ]; then printf '%s' "$FAKE_TAG"; exit 0; fi
dir=""; pats=()
while [ $# -gt 0 ]; do
	case "$1" in --dir) dir="$2"; shift ;; --pattern) pats+=("$2"); shift ;; esac
	shift
done
for p in "${pats[@]}"; do [ -n "${FAKE_NO_DEB:-}" ] || : > "$dir/$p"; done
GH
	cat > "$F/bin/python3" <<'PY'
#!/usr/bin/env bash
# python3 -I -m venv DIR makes DIR/bin/python, which logs what it is asked and refuses verify-sig.py on request.
if [ "$3" = venv ]; then
	mkdir -p "$4/bin"
	cat > "$4/bin/python" <<'INNER'
#!/usr/bin/env bash
echo "$*" >> "$RUNNER_TEMP/python.log"
case "$*" in *verify-sig.py*) exit "${FAKE_VERIFY_RC:-0}" ;; esac
exit 0
INNER
	chmod +x "$4/bin/python"
fi
PY
	chmod +x "$F/bin/gh" "$F/bin/python3"
	rc=0
	fetch() { # <tag> [VAR=value]...: a fresh RUNNER_TEMP, the step run, $rc and $out set
		RT="$WORK/rt"; rm -rf "$RT"; mkdir -p "$RT"
		local tag="$1"; shift
		run_step "$F" "$HERE" PATH="$F/bin:$PATH" RUNNER_TEMP="$RT" GITHUB_WORKSPACE="$HERE" FAKE_TAG="$tag" "$@"
	}
	fetch ""; check "with no release published the step succeeds and records nothing to upgrade from" "0 published=" "$rc $(cat "$RT/published.env")"
	fetch "latest"; check "a release whose name is not a version is refused" "1 1" "$rc $(says 'which is not a version')"
	fetch "v6.2.0+r12" FAKE_NO_DEB=1; check "a release without the package is refused" "1 1" "$rc $(says 'does not carry exactly')"
	fetch "v6.2.0+r12" FAKE_VERIFY_RC=1; check "a package whose signature does not verify stops the step, and nothing is recorded" "1 0" "$rc $(cat "$RT/published.env" 2> /dev/null | grep -c 'published=podman')"
	fetch "v6.2.0+r12"
	check "a verified package is recorded under the name of its tag" "0 published=podman_6.2.0+r12_amd64.deb" "$rc $(cat "$RT/published.env")"
	if grep -qvE '^[[:space:]]*(#|$)' "$HERE/keyring/glyndor-release-mldsa65.b64"; then want=1; else want=0; fi
	check "the second signature is required exactly when the anchor holds a key for it" "$want" "$(grep -c -e '--require-mldsa' "$RT/python.log")"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that fetches the published package"
fi


echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
