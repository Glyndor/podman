#!/usr/bin/env bash
#
# The step of reusable-workflow-lint.yml that runs actionlint is read from the workflow and run here with an
# actionlint that writes its arguments down: it has to be pointed at the shellcheck that the step before it
# installed and wrote to GITHUB_ENV, and not at whatever the runner has, and it has to run in the caller's
# checkout with no other flag that would silence a finding.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/reusable-workflow-lint.yml"
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
steps = doc["jobs"]["workflow-lint"]["steps"]
names = [s.get("name", "") for s in steps]
run = [s for s in steps if s.get("name", "").startswith("Run actionlint")]
shellcheck = [s for s in steps if s.get("name", "").startswith("Install shellcheck")]
if len(run) != 1 or len(shellcheck) != 1:
    sys.exit(f"{len(run)} run steps and {len(shellcheck)} shellcheck steps")
open(f"{out}/run.sh", "w").write(run[0]["run"])
open(f"{out}/env", "w").write("\n".join(f"{k}={v}" for k, v in run[0].get("env", {}).items()))
open(f"{out}/shellcheck.sh", "w").write(shellcheck[0]["run"])
open(f"{out}/order", "w").write(",".join(str(names.index(n)) for n in (shellcheck[0]["name"], run[0]["name"])))
PY
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/args"\n' "$WORK" > "$WORK/bin/actionlint"
chmod +x "$WORK/bin/actionlint"
check "the step passes the shellcheck of the install step through its environment" "SHELLCHECK_BIN=\${{ env.SHELLCHECK_BIN }}" "$(cat "$WORK/env")"
(SHELLCHECK_BIN=/opt/pinned/shellcheck PATH="$WORK/bin:$PATH" bash -e "$WORK/run.sh" > /dev/null 2>&1); rc=$?
check "actionlint is run, and exits 0 when it finds nothing" 0 "$rc"
check "it is given the shellcheck that was installed, as one argument" "-shellcheck=/opt/pinned/shellcheck" "$(grep -e '^-shellcheck=' "$WORK/args")"
check "and no flag besides colour and that one" "-color -shellcheck=/opt/pinned/shellcheck" "$(tr '\n' ' ' < "$WORK/args" | sed 's/ $//')"
check "the install step writes the path to GITHUB_ENV under that name" 1 "$(grep -c -E '^[[:space:]]*echo "SHELLCHECK_BIN=\$dir/shellcheck" >> "\$GITHUB_ENV"$' "$WORK/shellcheck.sh")"
check "and the install comes before the run" "1" "$([ "$(cut -d, -f1 "$WORK/order")" -lt "$(cut -d, -f2 "$WORK/order")" ] && echo 1 || echo 0)"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/actionlint"
(SHELLCHECK_BIN=/x PATH="$WORK/bin:$PATH" bash -e "$WORK/run.sh" > /dev/null 2>&1); rc=$?
check "a finding fails the step" 1 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
