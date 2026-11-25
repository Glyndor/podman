# How a release is made

The README shows the pipeline as a diagram; these are its steps in full.

- A scheduled workflow looks for the newest stable tag of [Podman](https://github.com/podman-container-tools/podman), [netavark](https://github.com/containers/netavark) and [aardvark-dns](https://github.com/containers/aardvark-dns) every six hours. Pre-releases are ignored. A new tag of any of the three starts a release.
- Each tag must be an annotated tag signed by a key listed in [containers/release-keys](https://github.com/containers/release-keys); the keys are kept in `keyring/podman/`. An unsigned, expired or unknown signature stops the run.
- The package is built from the official sources with the upstream `make` targets. Rust and Go come from Debian's own `trixie-backports`.
- Before signing, the same package is installed on clean Debian 13, Ubuntu 24.04 and Ubuntu 26.04, and runs a container on each, including one on a bridge network.
- It links only libc and libm (both in `libc6`), libgcc and libseccomp, so one package serves every release. Signature checks use Go's OpenPGP instead of gpgme, and subid and sqlite are not linked, because those libraries are renamed between releases. Debian 12 and Ubuntu 22.04 are not supported: their glibc is older than netavark needs, and each build installs the package on both to show that apt refuses it.
- On Ubuntu 24.04 the package uses `runc`, because that release's `crun` is too old for current Podman.
- Last, the package replaces Podman on the build runner itself, an Ubuntu virtual machine, runs a rootless container on `pasta`, and stops the last container of a rootless bridge network through the API, which the containers above cannot do.
- The job that signs declares the `release` environment, whose deployment policy admits the branch `main` only: GitHub decides that outside the workflow, so a branch that edits the guard of the workflow to run the signing job is refused the deployment. The keys are still secrets of the organization until their owner moves them into that environment. The job takes each package by the id and digest its build job reported when it uploaded the artifact, checks the list of the run for them, for the commit and for expiry, and signs only the file whose sha256 the build took before anything ran it; the build uploads the package before any test, and a separate job installs and tests the downloaded copy. The release tag is made by the API on the commit the plan fixed, and the release is created only for that tag, so a tag that somebody made during the build stops the run instead of being adopted. Every workflow runs its steps with `shell: bash`, which is `bash -e -o pipefail`.
- A rehearsal runs the same path without a release: `gh workflow run release.yml --ref main -f dry_run=true`, or Run workflow from `main` in the Actions tab with `dry_run` on. It builds even when nothing is new, under a version no release has (`+r999`), signs with keys made for that run and never reads the signing secrets, checks every signature, and ends with a job that shows no release was created. Nothing is attested or published.
- If any step fails nothing is published, and the previous release remains the latest. A failed scheduled run also opens an issue in this repository.

Each release carries one `.deb` and one detached `.sig` per architecture, and a build provenance attestation. [Verifying a package](verify.md) shows how to check them.

## What the package contains

The configuration of the release is under `/usr/share/containers`, and the package ships no file under `/etc/containers`, which is the administrator's: Podman reads `containers.conf`, `registries.conf` and `policy.json` from there when `/etc` has none. buildah and skopeo of Debian and Ubuntu read the policy only from `/etc/containers/policy.json`, so `postinst` copies the default there when there is none, once. Releases before `6.2.0+r12` shipped that file as part of the package; on the upgrade from one of them an edited file is kept and an unedited one is replaced by the new default.

The package replaces Debian's `netavark`, `aardvark-dns`, `golang-github-containers-common`, `podman-remote` and `passt`, and apt removes them when it installs the package. It carries its own `netavark` and `aardvark-dns`, `passt` and `pasta` (built from Debian's signed source of a release newer than the one Podman 6.2.0 asks for), and the containers-common configuration of the release. Other dependencies such as `conmon` and `crun` come from Debian.

## Versions

Release versions follow Podman's (`6.2.0`), with a `+rN` suffix when netavark, aardvark-dns or the way the package is built (everything under `scripts/build/`) changes under the same Podman. The first build of a version is revision 1 and carries no suffix, so the second one is `+r2` and there is no `+r1`. A packaging fix is the most common reason for one.

Before anything is signed, the job `config-upgrade` of `release.yml` runs on a machine of its own: it downloads the newest published release, verifies its signatures against the keys committed in `keyring/`, and upgrades it to the new package on Debian 13 and Ubuntu 24.04 and 26.04 with `scripts/verify/config-upgrade-test.sh`, with `policy.json` unedited, edited and deleted. `publish` waits for it.
