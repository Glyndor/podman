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
`scripts/build/`, makes the next scheduled run publish a new `+rN` release.

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
shellcheck -S warning scripts/*/*.sh tests/*/*.sh
scripts/quality/check-test-coverage.sh
for t in tests/*/*.test.sh; do bash "$t"; done
```

Every script in `scripts/` needs a test; `check-test-coverage.sh` fails when one
does not. The scripts that need root inside a container of a given release
(`scripts/verify/smoke-test.sh`, `scripts/verify/refuse-test.sh`, `scripts/verify/rootless-test.sh`) have their
argument contract tested here and their real run in `reusable-build.yml`, which
`release.yml` runs before anything is signed and `build-check.yml` runs on a pull
request that changes how the package is built.

One suite needs a library the distributions do not carry: `tests/ci/release-signing-mldsa.test.sh`
makes and verifies real ML-DSA-65 signatures, and the `python3-cryptography` of Debian and
Ubuntu has no ML-DSA. `tests.yml` runs it in a virtual environment built from
`.github/scripts/release/sign-requirements.txt`, pinned by hash. Run without that
environment first on `PATH`, the suite fails and says what is missing; it does not skip.

**A test you have not watched fail is not a test.** Before claiming a check
works, remove the control it covers, run it, and confirm it goes red for the
reason it names. Assert which failure fired, never that some failure did.

## Workflows

| file | what fails there |
|---|---|
| `tests.yml` | the suite and shellcheck |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `commit-hygiene.yml` | a commit carries a personal email address, or the change adds a line shaped like a credential |
| `release.yml` | the scheduled plan, build, smoke test, signing and publish; also runs when `scripts/build`, `keyring` or the workflow itself changes, and only publishes from `main`; opens an issue when a scheduled or push run fails |
| `reusable-build.yml` | the build, the smoke test on Debian 13 and Ubuntu 24.04 and 26.04, the check that Ubuntu 22.04 refuses the package, and a rootless container on the runner itself, for one architecture; called by `release.yml` and `build-check.yml` |
| `build-check.yml` | `package builds`: a pull request that touches `scripts/build/`, `scripts/verify/`, `scripts/upstream/`, `keyring/podman/`, the build workflows or `scripts/ci/decide-build.sh` compiles the package on both architectures; any other pull request skips the build and passes |
| `watchdog.yml` | the newest release is missing something upstream, or a change to the build recipe, that has waited more than a day; opens an issue when the scheduled run finds it |
| `dependabot-automerge.yml` | arms auto-merge on Dependabot's pull requests, which then merge when the required checks pass, and asks Dependabot to rebase the ones that fall behind |

Job ids are load-bearing. A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check and
leaves a phantom one the ruleset still requires. Renaming a job is a ruleset
change.

## Security

Never open a public issue for a vulnerability. Use the Security tab, then
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and is
deliberately not duplicated in this repository.
