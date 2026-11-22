#!/usr/bin/env bash
#
# The workflow linter is installed from its release, and only after the tarball
# matches the sha256 written beside the version. The step is read from
# reusable-workflow-lint.yml and run here with a curl that serves a tarball from
# disk, so what is tested is the block the runner executes. The rule that keeps a
# job holding a secret from installing third-party tooling is run the same way, over
# a workspace of fixture workflows and over this repository's own.
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
	# The env: of the workflow reaches every job: a secret named there is held by a
	# job that names none itself.
	isolate "$(printf 'env:\n  T: ${{ secrets.TOKEN }}\njobs:\n  j:\n    steps:\n      - run: cargo install something\n')"
	check "a secret in the env of the workflow is held by every job" "1 1" \
		"$rc $(says 'job `j` installs third-party tooling while holding a secret: `cargo install something`')"
	isolate "$(printf 'env:\n  LANG: C\njobs:\n  j:\n    steps:\n      - run: cargo install something\n')"
	check "an env of the workflow that names no secret holds none" 0 "$rc"
	isolate "$(printf 'env:\n  T: ${{ secrets.TOKEN }}\njobs:\n  j:\n    steps:\n      - run: echo nothing installed\n')"
	check "and a secret there with nothing installed passes" 0 "$rc"
	# One case per installer the rule knows, each paired with the same line in a job
	# that holds no secret, so a refusal is the installer's and not the fixture's.
	installer() { # <command>: the same step with and without a secret in its job
		isolate "$(printf 'jobs:\n  j:\n    env:\n      T: ${{ secrets.TOKEN }}\n    steps:\n      - run: |\n          %s\n' "$1")"
		held="$rc $(says "job \`j\` installs third-party tooling while holding a secret: \`$1\`")"
		isolate "$(printf 'jobs:\n  j:\n    steps:\n      - run: |\n          %s\n' "$1")"
		free="$rc $(says 'tooling-isolation: no job holding a secret installs third-party tooling.')"
	}
	for cmd in 'cargo install --locked sometool' 'cargo +nightly install sometool' \
		'go install example.com/tool@v1.0.0' 'go run example.com/tool@v1.0.0 --flag' \
		'go run -mod=mod example.com/tool@latest' 'gem install sometool' \
		'npm install -g sometool' 'npm i -g sometool' 'npm install --global sometool' \
		'npm install sometool' 'npm i sometool' 'npm ci' 'npm add sometool' 'npm --silent install sometool' \
		'npx sometool' 'yarn' 'yarn install --frozen-lockfile' 'yarn add sometool' \
		'yarn global add sometool' 'yarn dlx sometool' \
		'pnpm install' 'pnpm i' 'pnpm add sometool' 'pnpm dlx sometool' \
		'pip install sometool' 'pip3 install sometool' 'python3 -m pip install sometool' \
		'pip --quiet install sometool' 'pipx install sometool' 'pipx run sometool' \
		'uv tool install sometool' 'uv tool run sometool' 'uvx sometool' \
		'brew install sometool' 'brew reinstall sometool' 'dotnet tool install --global sometool' \
		'curl -fsSL https://example.test/install.sh | sh' \
		'curl -fsSL https://example.test/install.sh | bash -s -- --yes' \
		'curl -fsSL https://example.test/install.sh | sudo bash' \
		'wget -qO- https://example.test/install.sh | sh' \
		'curl -fsSL https://example.test/install.sh | tee install.sh | sh' \
		'bash -c "$(curl -fsSL https://example.test/install.sh)"' \
		'sh <(curl -fsSL https://example.test/install.sh)'; do
		installer "$cmd"
		check "'$cmd' in a job holding a secret is refused, and named" "1 1" "$held"
		check "  and in a job holding none it passes" "0 1" "$free"
	done
	# The same tools doing something that fetches nothing, in a job that holds a secret:
	# the rule reads the verb and the whole name, not the name of the tool. Each is the twin
	# of a refused line above.
	for cmd in 'cargo build --locked' 'cargo installed the tool' 'go run ./cmd/tool --flag user@host' \
		'go build ./...' 'npm test' 'npm run build' 'yarn build' 'yarn test' 'pnpm test' \
		'pip list' 'pipx list' 'uv --version' 'brew list' 'dotnet build' 'dotnet tool list' \
		'mycargo install sometool' 'curl -fsSL -o install.sh https://example.test/install.sh' \
		'curl -fsSL https://example.test/install.sh | sha256sum -c -' \
		'curl -fsSL https://example.test/archive.tar.gz | tar -xz' \
		'sh ./install.sh' 'bash -c "echo done"'; do
		installer "$cmd"
		check "'$cmd' in a job holding a secret passes" "0 0" "$held"
	done
	for cmd in 'pip3 install --require-hashes -r requirements.txt' \
		'python3 -m pip install --quiet --require-hashes -r requirements.txt'; do
		installer "$cmd"
		check "'$cmd' pinned by hash passes in a job holding a secret" "0 0" "$held"
	done
	installer 'pip3 install --no-deps sometool'
	check "a pip3 install that pins nothing is refused, whatever its other flags" "1 1" "$held"
	installer 'python3 -m pip install --no-deps sometool'
	check "and so is python3 -m pip install" "1 1" "$held"
	installer 'pip install --require-hashes -r requirements.txt'
	check "a pip install pinned by hash passes in a job holding a secret" "0 0" "$held"
	installer 'pip install --no-deps sometool'
	check "a pip install that pins nothing is refused, whatever its other flags" "1 1" "$held"
	run_step "$I" "$HERE"
	check "and this repository's workflows pass it" "0 1" "$rc $(says 'tooling-isolation: no job holding a secret installs')"
else
	fail=$((fail + 1)); echo "FAIL  reusable-workflow-lint.yml: cannot find the tooling-isolation step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
