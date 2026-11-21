#!/usr/bin/env bash
#
# Tests for the rebase step of .github/workflows/dependabot-automerge.yml: every
# push to main asks Dependabot to rebase the pull requests that fell behind, and
# only those. The step is read from the workflow and run here with a gh that
# lists pull requests from a fixture (through the step's own jq program) and
# answers how far behind each head is.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$HERE/.github/workflows/dependabot-automerge.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

python3 - "$WF" "$WORK" <<'PY' || { echo "FAIL  cannot read the step"; exit 1; }
import shlex, sys, yaml
path, out = sys.argv[1:3]
with open(path) as fh:
    steps = yaml.safe_load(fh)["jobs"]["rebase"]["steps"]
hits = [s for s in steps if s.get("name") == "Ask Dependabot to rebase its open pull requests"]
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} steps for the rebase")
with open(f"{out}/run.sh", "w") as fh:
    fh.write(hits[0]["run"])
with open(f"{out}/env.sh", "w") as fh:
    for k, v in (hits[0].get("env") or {}).items():
        if "${{" not in str(v):
            fh.write(f"export {k}={shlex.quote(str(v))}\n")
PY
check "the run block has no expression in it" 0 "$(grep -c '\${{' "$WORK/run.sh")"

# gh: `pr list` runs the step's jq over $LIST; `api repos/<r>/compare/main...<sha>` answers
# the number in $BEHIND_<sha>, or fails when it is "fail" or unset; `pr comment` is logged.
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"pr list")
		[ -z "${LIST_FAILS:-}" ] || exit 1
		while [ $# -gt 0 ]; do [ "$1" = --jq ] && { jq -r "$2" "$LIST"; exit; }; shift; done
		exit 1 ;;
	"api repos/"*)
		sha="${2##*...}"; var="BEHIND_$sha"
		echo "compare $2" >> "$LOG"
		[ -n "${!var:-}" ] && [ "${!var}" != fail ] || exit 1
		echo "${!var}" ;;
	"pr comment") echo "comment $3 $*" >> "$LOG" ;;
	*) exit 1 ;;
esac
GH
chmod +x "$WORK/bin/gh"

run_step() { # [VAR=value]...: sets $rc and $out; the comments are in $WORK/log
	: > "$WORK/log"
	rc=0
	out="$(
		# shellcheck source=/dev/null
		. "$WORK/env.sh"
		env PATH="$WORK/bin:$PATH" LIST="$WORK/list.json" LOG="$WORK/log" GH_REPO=Glyndor/podman "$@" \
			bash --noprofile --norc -eo pipefail "$WORK/run.sh" 2>&1
	)" || rc=$?
}
commented() { grep '^comment' "$WORK/log" | cut -d' ' -f2 | tr '\n' ' '; }

printf '[{"number":5,"headRefOid":"aaa"},{"number":9,"headRefOid":"bbb"},{"number":12,"headRefOid":"ccc"}]' > "$WORK/list.json"

run_step BEHIND_aaa=0 BEHIND_bbb=0 BEHIND_ccc=0
check "branches that have every commit of main get no comment" "0 " "$rc $(commented)"

run_step BEHIND_aaa=0 BEHIND_bbb=3 BEHIND_ccc=0
check "only the branch that is behind is asked" "0 9 " "$rc $(commented)"
check "and the comparison is against main with its head commit" 1 "$(grep -c 'compare repos/Glyndor/podman/compare/main...bbb' "$WORK/log")"
check "the request is the one Dependabot understands" 1 "$(grep -c -- '--body @dependabot rebase' "$WORK/log")"

run_step BEHIND_aaa=2 BEHIND_bbb=1 BEHIND_ccc=7
check "every branch that is behind is asked" "0 5 9 12 " "$rc $(commented)"

# When the count cannot be read the branch is asked anyway.
run_step BEHIND_aaa=0 BEHIND_bbb=fail
check "a comparison that fails asks that branch" "0 9 12 " "$rc $(commented)"
run_step BEHIND_aaa=not-a-number BEHIND_bbb=0 BEHIND_ccc=0
check "an answer that is not a number asks that branch" "0 5 " "$rc $(commented)"

printf '[]' > "$WORK/list.json"
run_step
check "no open pull requests, nothing to do" "0 " "$rc $(commented)"
check "and no comparison is made" 0 "$(grep -c '^compare' "$WORK/log")"

printf '[{"number":5,"headRefOid":"aaa"}]' > "$WORK/list.json"
run_step LIST_FAILS=1
check "a list that cannot be read stops the job" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'could not list the open pull requests')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
