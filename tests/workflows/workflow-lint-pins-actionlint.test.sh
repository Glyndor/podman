#!/usr/bin/env bash
#
# The workflow linter is installed from its release, and only after the tarball
# matches the sha256 written beside the version. The step is read from
# reusable-workflow-lint.yml and run here with a curl that serves a tarball from
# disk, so what is tested is the block the runner executes. The rule that keeps a
# job holding a secret from installing third-party tooling is run the same way, over
# a workspace of fixture workflows and over this repository's own.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$HERE/.github/workflows/reusable-workflow-lint.yml"
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
    doc = yaml.safe_load(fh)
steps = doc["jobs"]["workflow-lint"]["steps"]
hits = [s for s in steps if s.get("name") == "Install actionlint"]
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} steps named 'Install actionlint'")
with open(f"{out}/run.sh", "w") as fh:
    fh.write(hits[0]["run"])
with open(f"{out}/env.sh", "w") as fh:
    for k, v in hits[0]["env"].items():
        fh.write(f"export {k}={shlex.quote(str(v))}\n")
# The toolchain the install used to need must not come back by another step.
uses = [s.get("uses", "") for s in steps]
with open(f"{out}/toolchain", "w") as fh:
    fh.write("\n".join(u for u in uses if u.startswith(("actions/setup-go", "actions/cache"))))
PY
check "no Go toolchain or cache step sits beside the pinned download" "" "$(cat "$WORK/toolchain")"
check "the run block has no expression in it" 0 "$(grep -c '\${{' "$WORK/run.sh")"
check "the pin is a 64 digit sha256" 1 "$(grep -c -E '^export ACTIONLINT_SHA256=[0-9a-f]{64}$' "$WORK/env.sh")"
check "and a release tag" 1 "$(grep -c -E '^export ACTIONLINT_VERSION=v[0-9]+\.[0-9]+\.[0-9]+$' "$WORK/env.sh")"

# The release as curl serves it: a tarball with an actionlint inside.
mkdir -p "$WORK/release" "$WORK/bin"
printf '#!/bin/sh\necho fake actionlint\n' > "$WORK/release/actionlint"
chmod +x "$WORK/release/actionlint"
tar -czf "$WORK/release.tar.gz" -C "$WORK/release" actionlint
good="$(sha256sum "$WORK/release.tar.gz" | cut -d' ' -f1)"
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
# curl -sSfL -o <file> <url>: records the url and writes the tarball.
while [ $# -gt 0 ]; do
	case "$1" in -o) out="$2"; shift ;; http*) echo "$1" > "$LOG_DIR/url" ;; esac
	shift
done
cp "$TARBALL" "$out"
CURL
chmod +x "$WORK/bin/curl"

install() { # <sha256 to expect>; sets $rc and $out
	rm -rf "$WORK/rt" "$WORK/path"; mkdir -p "$WORK/rt"; : > "$WORK/path"
	rc=0
	out="$(
		# shellcheck source=/dev/null
		. "$WORK/env.sh"
		PATH="$WORK/bin:$PATH" LOG_DIR="$WORK" TARBALL="$WORK/release.tar.gz" ACTIONLINT_SHA256="$1" \
			RUNNER_TEMP="$WORK/rt" GITHUB_PATH="$WORK/path" \
			bash --noprofile --norc -eo pipefail "$WORK/run.sh" 2>&1
	)" || rc=$?
}

install "$good"
check "a tarball that matches its hash is installed" "0 1" "$rc $(grep -c 'actionlint-bin' "$WORK/path")"
check "and the tool is where the later steps will find it" 1 "$([ -x "$WORK/rt/actionlint-bin/actionlint" ] && echo 1 || echo 0)"
check "the download is the linux amd64 build of the pinned tag" 1 \
	"$(grep -c -E '/download/v[0-9.]+/actionlint_[0-9.]+_linux_amd64\.tar\.gz$' "$WORK/url")"

install "0000000000000000000000000000000000000000000000000000000000000000"
check "a tarball that does not match is refused" "1 0" "$rc $(grep -c 'actionlint-bin' "$WORK/path")"
check "and nothing is extracted from it" 0 "$([ -e "$WORK/rt/actionlint-bin/actionlint" ] && echo 1 || echo 0)"
check "and the failure is the hash check" 1 "$(printf '%s\n' "$out" | grep -c 'FAILED')"

# --- tooling isolation -------------------------------------------------------------
# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"
I="$WORK/isolation"
if step reusable-workflow-lint.yml workflow-lint "name=A job holding a secret must not install third-party tooling" "$I"; then
	isolate() { # <workflow body>: a workspace with that one workflow; sets $rc and $out
		rm -rf "$I/ws"; mkdir -p "$I/ws/.github/workflows"
		printf '%s\n' "$1" > "$I/ws/.github/workflows/w.yml"
		run_step "$I" "$I/ws"
	}
	secret='jobs:\n  j:\n    env:\n      T: ${{ secrets.TOKEN }}\n    steps:\n      - run: |\n'
	isolate "$(printf "$secret"'          cargo install something\n')"
	check "a job holding a secret that runs cargo install is refused, and named" "1 1" \
		"$rc $(says 'job `j` installs third-party tooling while holding a secret: `cargo install something`')"
	isolate "$(printf "$secret"'          pip install --require-hashes -r requirements.txt\n')"
	check "one whose install is pinned by hash passes" "0 1" "$rc $(says 'tooling-isolation: no job holding a secret installs third-party tooling.')"
	isolate "$(printf 'jobs:\n  j:\n    steps:\n      - run: cargo install something\n')"
	check "an install in a job that holds no secret passes" 0 "$rc"
	run_step "$I" "$HERE"
	check "and this repository's workflows pass it" "0 1" "$rc $(says 'tooling-isolation: no job holding a secret installs')"
else
	fail=$((fail + 1)); echo "FAIL  reusable-workflow-lint.yml: cannot find the tooling-isolation step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
