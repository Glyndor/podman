#!/usr/bin/env bash
#
# The step of tests.yml that installs the cryptography wheel for the ML-DSA-65 suite is read from the
# workflow and run here with a python3 that records what it is asked: the wheel has to come from the
# file that pins it, with hashes required and no source build, into a virtual environment of its own
# and by the python of that environment, and the suite that needs it has to find that environment first
# on PATH. A step that installed into the runner's python, or without --require-hashes, would still
# make the suite pass.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/tests.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

python3 - "$WF" "$WORK" <<'PY' || { echo "FAIL  cannot read the steps"; exit 1; }
import sys, yaml
path, out = sys.argv[1:3]
doc = yaml.safe_load(open(path))
steps = [s for job in doc["jobs"].values() for s in job.get("steps", [])]
wheel = [s for s in steps if s.get("name", "").startswith("Install the pinned cryptography wheel")]
suites = [s for s in steps if s.get("name") == "suites"]
if len(wheel) != 1 or len(suites) != 1:
    sys.exit(f"{len(wheel)} wheel steps and {len(suites)} suites steps")
open(f"{out}/wheel.sh", "w").write(wheel[0]["run"])
open(f"{out}/suites.sh", "w").write(suites[0]["run"])
PY

# A python3 that makes the virtual environment the step asks for, with a python that writes its arguments down.
mkdir -p "$WORK/bin" "$WORK/rt"
cat > "$WORK/bin/python3" <<'PY3'
#!/bin/sh
if [ "$1 $2" = "-m venv" ]; then
	mkdir -p "$3/bin"
	printf '#!/bin/sh\necho "$@" >> "%s/venv-calls"\n' "$WORK_DIR" > "$3/bin/python"
	chmod +x "$3/bin/python"
	echo "$3" > "$WORK_DIR/venv-dir"
else
	echo "system python3 was asked: $*" >> "$WORK_DIR/system-calls"
fi
PY3
chmod +x "$WORK/bin/python3"
(cd "$HERE" && WORK_DIR="$WORK" RUNNER_TEMP="$WORK/rt" PATH="$WORK/bin:$PATH" bash -e "$WORK/wheel.sh" > "$WORK/wheel.out" 2>&1); rc=$?
calls="$(cat "$WORK/venv-calls" 2>/dev/null)"
check "the step exits 0" 0 "$rc"
check "the virtual environment is made under RUNNER_TEMP, where the suites step looks for it" "$WORK/rt/mldsa-venv" "$(cat "$WORK/venv-dir" 2>/dev/null)"
check "the system python3 is asked for nothing but the environment" "" "$(cat "$WORK/system-calls" 2>/dev/null)"
check "the wheel is installed by pip of the environment, from the file that pins it" 1 "$(printf '%s\n' "$calls" | grep -c -E -- '^-m pip install .*-r \.github/scripts/release/sign-requirements\.txt$')"
check "with the hashes required" 1 "$(printf '%s\n' "$calls" | grep -c -e '--require-hashes')"
check "and no source build" 1 "$(printf '%s\n' "$calls" | grep -c -e '--only-binary=:all:')"
check "and only one install is made" 1 "$(printf '%s\n' "$calls" | grep -c 'pip install')"
check "the suite that needs ML-DSA runs with that environment first on PATH" 1 \
	"$(grep -c -F -e '*-mldsa.test.sh) PATH="$RUNNER_TEMP/mldsa-venv/bin:$PATH" bash "$t"' "$WORK/suites.sh")"
check "and it is not the way every suite runs" 1 "$(grep -c -F -e 'mldsa-venv' "$WORK/suites.sh")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
