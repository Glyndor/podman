# Contributing to Glyndor/podman

This repository has its own guide because the organisation's shared one
describes a `topic → develop → main` flow that does not exist here.

Contributions are invitation-only. Bug reports and ideas through issues are
welcome; unsolicited pull requests are not accepted.

## What this repository is

It builds, signs and publishes the Podman `.deb` that apt.glyndor.net serves. It
carries no Podman source. A scheduled workflow looks for the newest stable
tag of Podman, netavark and aardvark-dns, verifies each tag's signature against
the keys in `keyring/podman/`, builds one package for `amd64` and `arm64`, tries
it on clean Debian 13, Ubuntu 24.04 and Ubuntu 26.04 and checks that Ubuntu
22.04 refuses it, and only then signs and publishes it.

Nothing is released by hand. A change to how the package is built, anything under
`scripts/build/`, makes the next scheduled run publish a new `+rN` release. The
workflows call that content the recipe: its id is a hash of those files, and a
release records the id it was built with in `components.txt`.

Two files in `keyring/` decide the second, ML-DSA-65 signature of a release:
`glyndor-release-mldsa65.b64` holds its public key, and the line `required` in
`second-signature-required` makes it mandatory for every release. Each one changes
in a pull request of its own. The line is not the only thing that requires the
second signature: so does the secret `GLYNDOR_RELEASE_MLDSA65_KEY` being set, and so
does the newest release already carrying it. While any of the three holds, a key
file left without a key stops the release instead of publishing Ed25519 alone, and
a key in the file with no secret stops it too. Taking the line out therefore does
not retire the second signature: it stays required for as long as the secret is
set or the newest release carries it. `docs/verify.md` and the README say whether
it is required, and a test holds them to the file.

## Branch flow

```
topic branch ──PR──▶ main
```

There is no `develop`. Branch from `main`, open a pull request against `main`,
squash-merge back. `Closes #N` auto-closes, because the fix lands on the default
branch.

## Before you open a pull request

- **An issue first.** Labels are the tracking system here. Apply `type:`,
  `prio:`, `effort:`, `status:` and `area:` where they fit.
- **Sign every commit off** with `git commit -s`, using your GitHub noreply address (`git config user.email`). The `dco` check is required, and `commit hygiene` rejects any other address in the author, `Signed-off-by` or `Co-authored-by`.
- **Commits are signed**, GPG or SSH, and rebase-merge is disabled because GitHub
  re-creates rebased commits without signatures.
- **Conventional Commit title** on the pull request. It becomes the squashed
  commit message.

## Tests

```sh
find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck -S warning
bash scripts/quality/check-test-coverage.sh
bash scripts/quality/check-mutation-coverage.sh
bash scripts/quality/check-folder-size.sh
python3 -m venv /tmp/podman-mldsa && /tmp/podman-mldsa/bin/python -m pip install --quiet --require-hashes --only-binary=:all: -r .github/scripts/release/sign-requirements.txt
status=0; for t in $(find tests -name '*.test.sh' | sort); do case "$t" in *-mldsa.test.sh) PATH="/tmp/podman-mldsa/bin:$PATH" bash "$t" ;; *) bash "$t" ;; esac </dev/null || { echo "FAILED $t"; status=1; }; done; [ "$status" -eq 0 ]
```

The suites run on Debian or Ubuntu with bash, git, gpg, make, file, binutils, dpkg-dev,
shellcheck 0.11.0 (the version CI pins), and `python3` with `python3-yaml`,
`python3-cryptography` and `python3-venv`. The line that builds the virtual environment
needs network access once, to fetch the pinned wheel; the last one runs every suite, says
which failed, and exits non-zero when one did.

A folder holds at most twenty tracked files directly, and `check-folder-size.sh` fails when one
holds more: split it into subfolders by what each file is for. `.github/workflows` is left out, because
GitHub only reads it flat, and so is any `testdata` folder.

Every script in `scripts/`, shell or Python, needs a test; `check-test-coverage.sh` fails when one
does not. A script `scripts/<area>/x.sh` is tested by `tests/<area>/x.test.sh`. The
other folders of `tests/` are named for what they test: `tests/workflows` reads
`.github/workflows`, in one folder for each thing it holds (`release`, `build`, `dependabot`, `keyring`, `watchdog`,
`pr-checks`, `policy`, `mounts`, `pins`), `tests/release` exercises the signing tools in
`.github/scripts/release` with its vectors in `tests/release/fixtures`, `tests/docs`
holds the documents that make a claim about the repository, and `tests/lib` holds
helpers that suites source. `tests.yml` runs every `*.test.sh` under `tests/` at any depth. The scripts that install the package
(`scripts/verify/smoke-test.sh` and `scripts/verify/refuse-test.sh` as root inside a container of a given release,
`scripts/verify/rootless-test.sh` and `scripts/verify/rootless-stop-test.sh` on the runner) are tested here as far as stand-ins reach: their argument contract,
the checks `smoke-test.sh` hands to `scripts/verify/package-state.sh`, and the body of the two rootless scripts against a
faked machine. What no stand-in shows is the kernel, such as AppArmor refusing a signal; that is only seen on the runner. Their real run is in `reusable-build.yml`, which `release.yml` runs before anything is signed and
`build-check.yml` runs on a pull request that changes how the package is built.

One suite needs a library the distributions do not carry: `tests/release/release-signing-mldsa.test.sh`
makes and verifies real ML-DSA-65 signatures, and the `python3-cryptography` of Debian and
Ubuntu has no ML-DSA. `tests.yml` runs it in a virtual environment built from
`.github/scripts/release/sign-requirements.txt`, pinned by hash, and the commands above
do the same. Run without that environment first on `PATH`, the suite fails and says what
is missing; it does not skip.

Every refusal of a script or a workflow (an `exit` with a status, a `fail`, a
`sys.exit` with a message) has an entry in `tests/mutation/catalog.txt`: the text that
removes it, and the suites that must go red when it is gone. `check-mutation-coverage.sh`
names a refusal that has none, and one that cannot have one goes in
`tests/mutation/exemptions.txt` with what was measured. `bash tests/mutation/run-mutations.sh <id>`
applies one entry to a copy of the committed tree and runs its suites; with no id it
runs them all, which `mutation.yml` does every week. A control that is not a refusal (a
`:ro` on a mount, a flag handed to a tool, a version pinned in two places) is invisible to
that check, so it gets its entry and its test from whoever adds it.

**A test you have not watched fail is not a test.** Before claiming a check
works, remove the control it covers, run it, and confirm it goes red for the
reason it names. Assert which failure fired, never that some failure did.

## Workflows

| file | what fails there |
|---|---|
| `tests.yml` | the suite and shellcheck, every script has a test, and every refusal has a mutation entry or an exemption |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `reusable-dco.yml`, `reusable-line-limit.yml`, `reusable-workflow-lint.yml` | the rule behind each of the three above, which only call them. They live in this repository and are edited here, so a fix made to the organisation's workflow of the same name does not arrive by itself |
| `commit-hygiene.yml` | a commit carries a personal email address, or the change adds a line shaped like a credential. A repository that keeps throwaway test keys lists their paths in `.secret-scan-allow` on the base branch: one literal path per line, relative to the root, with a trailing `/` for a whole directory, and no wildcards or regular expressions (a line that has one fails the scan, naming it) |
| `release.yml` | the scheduled plan, build, smoke test, signing, the upgrade from the published release with an edited `policy.json` (a job of its own, which `publish` waits for) and publish; also runs when `scripts/build`, `keyring`, `release.yml` or `reusable-build.yml` changes, and only publishes from `main`; opens an issue when a scheduled or push run fails. Signing is a job of its own, with the keys and read access only: it takes the packages one artifact at a time, outside the checkout, and `scripts/release/check-artifacts.sh` requires exactly the names the tag implies before any key is read. The job that attests and publishes holds no key and verifies every signature again. Every job after the plan builds the commit the plan fixed |
| `reusable-build.yml` | the build, the smoke test on Debian 13 and Ubuntu 24.04 and 26.04, the check that Ubuntu 22.04 and Debian 12 refuse the package, a rootless container on the runner itself, and the stop of the last container of a rootless bridge network through the API, on the runner of one architecture; `release.yml` and `build-check.yml` each call it once for amd64 (ubuntu-26.04) and once for arm64 (ubuntu-24.04-arm) |
| `build-check.yml` | `package builds`: a pull request that touches `scripts/build/`, `scripts/verify/`, `scripts/upstream/`, `keyring/podman/`, the build workflows or `scripts/ci/decide-build.sh` compiles the package on both architectures; any other pull request skips the build and passes |
| `reusable-package.yml` | the build of the rpm of one distribution and one architecture in the container of that distribution, then its installation with the package manager of the distribution on a clean image and over the distribution's own Podman, containers with and without root, and its removal; `package-check.yml` calls it once for every row of `scripts/package/distros.txt` |
| `package-check.yml` | `packages build`: a pull request that touches `scripts/package/`, `scripts/upstream/`, `keyring/podman/`, the package workflows or `scripts/ci/decide-package.sh` builds the native packages for every distribution; any other pull request skips the build and passes |
| `watchdog.yml` | the newest release is missing something upstream, or a change to the build recipe, that has waited more than a day; opens an issue when the scheduled run finds it; also fails when `keyring-watch.yml` has not finished a scheduled run in two days, or `mutation.yml` in nine, and opens an issue for each |
| `mutation.yml` | `every catalogued guard is noticed`: each entry of `tests/mutation/catalog.txt` breaks one refusal of a script or workflow, and a suite it names has to go red. Weekly and on demand every entry; on a pull request only the entries the change can affect, decided from the base commit |
| `dependabot-automerge.yml` | arms auto-merge on Dependabot's pull requests, which then merge when the required checks pass, and asks Dependabot to rebase the ones that fall behind |
| `keyring-watch.yml` | the keys that sign Podman upstream are no longer the ones in `keyring/podman/`: it prepares a branch with the change and opens an issue, and it also opens one when fewer than two keys can still sign for the next sixty days |

Job ids are load-bearing. A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check and
leaves a phantom one the ruleset still requires. Renaming a job is a ruleset
change.

## Security

Never open a public issue for a vulnerability. Use the Security tab, then
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and is
deliberately not duplicated in this repository.
