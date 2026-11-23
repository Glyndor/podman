# shellcheck shell=bash
# shellcheck disable=SC2034 # rc and out are read by the suites that source this file
#
# Helpers for the suites that read a step out of a workflow and run it. Sourced,
# never run: the suite sets HERE (the repository root) and pass/fail/check first.
#
# step <workflow> <job> <name=STEP NAME | secret=SECRET> <out-dir>
# Writes the step's run block to <out-dir>/run.sh, an export line for each env value
# that is a literal to <out-dir>/env.sh, and the name of each env variable fed from a
# secret to <out-dir>/secrets. A step chosen by the secret it holds stays found when
# the step is renamed or given a second secret. Fails when not exactly one matches.
step() {
	mkdir -p "$4"
	python3 - "$HERE/.github/workflows/$1" "$2" "$3" "$4" <<'PY'
import re, shlex, sys, yaml
path, job, selector, out = sys.argv[1:5]
with open(path) as fh:
    doc = yaml.safe_load(fh)
steps = doc["jobs"][job]["steps"]
kind, _, want = selector.partition("=")
def holds(step, secret):
    pattern = re.compile(r"secrets\." + re.escape(secret) + r"(?!\w)")
    return any(pattern.search(str(v)) for v in (step.get("env") or {}).values())
if kind == "name":
    hits = [s for s in steps if s.get("name") == want]
else:
    hits = [s for s in steps if holds(s, want)]
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} steps in job {job} match {selector}")
env = hits[0].get("env") or {}
with open(f"{out}/run.sh", "w") as fh:
    fh.write(hits[0]["run"])
# The shell Actions starts for this step, not a stricter one: the step's own `shell`, else the job's
# defaults, else the workflow's, else the implicit one, which is `bash -e` and has no pipefail.
def default_shell(node):
    return ((node.get("defaults") or {}).get("run") or {}).get("shell")
shell = hits[0].get("shell") or default_shell(doc["jobs"][job]) or default_shell(doc)
flags = {"bash": "--noprofile --norc -eo pipefail", None: "-e"}
if shell not in flags:
    sys.exit(f"{path}: job {job} runs its steps with shell {shell!r}, which the helper does not reproduce")
with open(f"{out}/shell.flags", "w") as fh:
    fh.write(flags[shell])
with open(f"{out}/env.sh", "w") as fh:
    for k, v in env.items():
        if "${{" not in str(v):
            fh.write(f"export {k}={shlex.quote(str(v))}\n")
with open(f"{out}/secrets", "w") as fh:
    for k, v in env.items():
        if re.search(r"secrets\.\w", str(v)):
            fh.write(k + "\n")
PY
}

# run_step <step-dir> <working-dir> [VAR=value]...: runs the block as GitHub does, in the shell
# the workflow gives that step (`bash -e` unless it says `shell: bash`, which adds pipefail), with
# the step's literal env and the given variables. Sets $rc and $out.
run_step() {
	local dir="$1" wd="$2"; shift 2
	rc=0
	out="$(
		cd "$wd" || exit 99
		# shellcheck source=/dev/null
		. "$dir/env.sh"
		# shellcheck disable=SC2046 # the flags are words
		env "$@" bash $(cat "$dir/shell.flags") "$dir/run.sh" 2>&1
	)" || rc=$?
}
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }

# gate <workflow> <job> <if|needs> [step name]: prints the condition of a job, or of
# one of its steps when a name is given, or the jobs a job waits for (sorted, with a
# comma between them). Prints "no such job", "no such step" or nothing at all for an
# absent field, never a crash, so a missing gate reads as a difference.
gate() {
	python3 - "$HERE/.github/workflows/$1" "$2" "$3" "${4:-}" <<'PY' 2>&1 || echo "gate failed"
import sys, yaml
path, job, field, step = sys.argv[1:5]
with open(path) as fh:
    jobs = yaml.safe_load(fh)["jobs"]
if job not in jobs:
    print("no such job"); sys.exit(0)
node = jobs[job]
if step:
    hits = [s for s in node.get("steps") or [] if s.get("name") == step]
    if len(hits) != 1:
        print("no such step"); sys.exit(0)
    node = hits[0]
value = node.get(field)
if field == "needs":
    value = ",".join(sorted([value] if isinstance(value, str) else value or []))
print("" if value is None else str(value).strip())
PY
}
