#!/usr/bin/env bash
#
# The line-limit gate has to measure workflow files. Its extension list left out
# yml and yaml, so the largest files of this repository were the only ones it
# never counted, and the branch that treats # as a comment in YAML never ran.
# The step is read from the reusable, with the defaults its inputs declare, and
# run over a throwaway repository.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/reusable-line-limit.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# The run block, and the defaults of the inputs it is fed.
python3 - "$WF" "$WORK" <<'PY' || { echo "FAIL  cannot read the step"; exit 1; }
import shlex, sys, yaml
path, out = sys.argv[1:3]
with open(path) as fh:
    doc = yaml.safe_load(fh)
steps = doc["jobs"]["line-limit"]["steps"]
hits = [s for s in steps if s.get("name") == "Check file lengths"]
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} steps named 'Check file lengths'")
inputs = (doc.get("on") or doc.get(True))["workflow_call"]["inputs"]
with open(f"{out}/run.sh", "w") as fh:
    fh.write(hits[0]["run"])
with open(f"{out}/env.sh", "w") as fh:
    for env, key in (("HARD", "hard-limit"), ("SOFT", "soft-limit"), ("EXTS", "extensions"), ("EXCLUDE", "exclude-pattern")):
        fh.write(f"export {env}={shlex.quote(str(inputs[key]['default']))}\n")
PY

# gate <file> <code lines> <comment lines>: a repository whose only tracked file
# has that many lines; sets $rc and $out.
gate() {
	rm -rf "$WORK/repo"; mkdir -p "$WORK/repo/$(dirname "$1")"
	(
		cd "$WORK/repo" || exit 99
		for ((i = 0; i < $2; i++)); do echo "  key$i: value"; done > "$1"
		for ((i = 0; i < $3; i++)); do echo "  # note $i"; done >> "$1"
		git init -q . && git add -A
	)
	rc=0
	out="$(
		cd "$WORK/repo" || exit 99
		# shellcheck source=/dev/null
		. "$WORK/env.sh"
		bash --noprofile --norc -eo pipefail "$WORK/run.sh" 2>&1
	)" || rc=$?
}
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

gate .github/workflows/big.yml 501 0
check "a workflow past the hard limit fails the gate" "1 1" "$rc $(says '.github/workflows/big.yml has 501 code lines')"
gate .github/workflows/big.yaml 501 0
check "and so does one named .yaml" "1 1" "$rc $(says 'big.yaml has 501 code lines')"
gate .github/workflows/long.yml 301 0
check "a workflow past the soft limit warns and passes" "0 1" "$rc $(says 'soft limit 300')"
gate .github/workflows/commented.yml 10 700
check "comment lines in a workflow do not count" "0 0" "$rc $(says 'code lines')"
gate scripts/big.sh 501 0
check "a script past the hard limit still fails" "1 1" "$rc $(says 'scripts/big.sh has 501 code lines')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
