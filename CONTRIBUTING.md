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
- **Sign every commit off** with `git commit -s`. The `dco` check is required.
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
(`scripts/verify/smoke-test.sh`, `scripts/verify/refuse-test.sh`) have their
argument contract tested here and their real run in `release.yml`, before
anything is signed.

**A test you have not watched fail is not a test.** Before claiming a check
works, remove the control it covers, run it, and confirm it goes red for the
reason it names. Assert which failure fired, never that some failure did.

## Workflows

| file | what fails there |
|---|---|
| `tests.yml` | the suite and shellcheck |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `release.yml` | the scheduled plan, build, smoke test, signing and publish |

Job ids are load-bearing. A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check and
leaves a phantom one the ruleset still requires. Renaming a job is a ruleset
change.

## Security

Never open a public issue for a vulnerability. Use the Security tab, then
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and is
deliberately not duplicated in this repository.
