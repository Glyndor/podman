#!/usr/bin/env bash
#
# Tests for the two steps of reusable-build.yml that run on the runner itself, after the
# package is built and smoke-tested: the rootless container on pasta, and the stop of the
# last container of a bridge network through the API. Neither script can run in the
# containers the smoke test uses, so the steps are the only place they run. The workflow
# is read for what each step runs, in what order, and whether anything lets it be skipped,
# and a copy with each of those broken says what changed.
#
# A script whose step is gone, reordered before the install, made a no-op or allowed to
# fail leaves its own suite green and the check gone, which is how a pasta profile that
# refused the signal Podman sends it shipped.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# facts [workflow file]: one line per fact, and "reading failed" when it cannot be read.
facts() {
	python3 - "${1:-$HERE/.github/workflows/reusable-build.yml}" <<'PY' 2>&1 || echo "reading failed"
import sys, yaml

with open(sys.argv[1]) as fh:
    steps = yaml.safe_load(fh)["jobs"]["test"]["steps"]

def find(script):
    return [i for i, s in enumerate(steps) if script in str(s.get("run", ""))]

smoke, rootless, stop = find("verify/smoke-test.sh"), find("verify/rootless-test.sh"), find("verify/rootless-stop-test.sh")
print("steps that run the rootless test", len(rootless))
print("steps that run the stop test", len(stop))
if len(rootless) == 1 and len(stop) == 1 and smoke:
    r, s = rootless[0], stop[0]
    print("order: smoke test, rootless test, stop test", "yes" if max(smoke) < r < s else "no")
    print("stop test runs:", " ".join(str(steps[s]["run"]).split()))
    # The driver the override names, when a step between the two writes one and exports it.
    named = [str(x.get("run", "")) for x in steps[r + 1:s]
             if "CONTAINERS_CONF_OVERRIDE=" in str(x.get("run", "")) and "GITHUB_ENV" in str(x.get("run", ""))]
    driver = [w.split('"')[1] for run in named for w in run.split("firewall_driver = ")[1:2]]
    print("firewall driver named before the stop test:", " ".join(driver) or "none")
    print("stop test env: ROOTLESS_STOP_TEST_SUDO=" + str((steps[s].get("env") or {}).get("ROOTLESS_STOP_TEST_SUDO")))
    for name, i in (("rootless test", r), ("stop test", s)):
        skippable = any(k in steps[i] for k in ("if", "continue-on-error", "timeout-minutes"))
        print(name, "can be skipped or allowed to fail:", "yes" if skippable else "no")
PY
}

want='steps that run the rootless test 1
steps that run the stop test 1
order: smoke test, rootless test, stop test yes
stop test runs: bash scripts/verify/rootless-stop-test.sh
firewall driver named before the stop test: nftables
stop test env: ROOTLESS_STOP_TEST_SUDO=1
rootless test can be skipped or allowed to fail: no
stop test can be skipped or allowed to fail: no'
check "the workflow runs both on the runner, in that order, unconditionally" "$want" "$(facts)"

BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
broken() { # <sed expression>: what differs in the facts of a copy with that one edit
	cp "$HERE/.github/workflows/reusable-build.yml" "$BAD/w.yml"
	sed -i "$1" "$BAD/w.yml"
	diff -q "$HERE/.github/workflows/reusable-build.yml" "$BAD/w.yml" >/dev/null && { echo "SABOTAGE INERT"; return; }
	facts "$BAD/w.yml" | diff <(printf '%s\n' "$want") - | sed -n 's/^> //p'
}
check "a stop test whose step runs nothing is named" "steps that run the stop test 0" \
	"$(broken 's|run: bash scripts/verify/rootless-stop-test.sh|run: "true"|' | grep '^steps that run the stop test')"
check "a stop test that reads the kernel log without sudo is named" "stop test env: ROOTLESS_STOP_TEST_SUDO=0" \
	"$(broken 's|ROOTLESS_STOP_TEST_SUDO: "1"|ROOTLESS_STOP_TEST_SUDO: "0"|' | grep '^stop test env')"
check "a stop test left to the firewall driver of the runner image is named" "firewall driver named before the stop test: none" \
	"$(broken '/^      - name: Name the firewall driver this netavark has$/,/GITHUB_ENV/d' | grep '^firewall driver')"
check "an override that names a driver netavark 2 does not have is named" "firewall driver named before the stop test: iptables" \
	"$(broken 's|firewall_driver = "nftables"|firewall_driver = "iptables"|' | grep '^firewall driver')"
check "a stop test allowed to fail is named" "stop test can be skipped or allowed to fail: yes" \
	"$(broken 's|^\(      - name: Stop the last container of a bridge network.*\)$|\1\n        continue-on-error: true|' | grep '^stop test can be')"
check "a stop test that runs only on some events is named" "stop test can be skipped or allowed to fail: yes" \
	"$(broken 's|^\(      - name: Stop the last container of a bridge network.*\)$|\1\n        if: ${{ false }}|' | grep '^stop test can be')"
check "a rootless test allowed to fail is named" "rootless test can be skipped or allowed to fail: yes" \
	"$(broken 's|^\(      - name: Run a rootless container on pasta.*\)$|\1\n        continue-on-error: true|' | grep '^rootless test can be')"
check "a rootless test that is no longer run is named" "steps that run the rootless test 0" \
	"$(broken 's|bash scripts/verify/rootless-test.sh |echo |' | grep '^steps that run the rootless test')"

# The stop test before the step that installs the package would run against the Podman the
# runner came with, and pass without having seen the package.
python3 - "$HERE/.github/workflows/reusable-build.yml" "$BAD/swapped.yml" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
first = next(i for i, l in enumerate(lines) if l.startswith("      - name: Run a rootless container on pasta"))
second = next(i for i, l in enumerate(lines) if l.startswith("      # The package is installed by the step above."))
# The test job is the last of the file: its steps end where the file does.
end = len(lines)
lines[first:end] = lines[second:end] + lines[first:second]
open(sys.argv[2], "w").write("\n".join(lines))
PY
check "a stop test moved before the rootless test, which installs the package, is named" "order: smoke test, rootless test, stop test no" \
	"$(facts "$BAD/swapped.yml" | diff <(printf '%s\n' "$want") - | sed -n 's/^> //p' | grep '^order')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
