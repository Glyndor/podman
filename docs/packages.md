# Native packages

Besides the `.deb`, this repository builds Podman as an rpm for the distributions listed in
[`scripts/package/distros.txt`](../scripts/package/distros.txt). They are built from the same three upstream
tags as the `.deb`, whose signatures are verified the same way, and they carry the same decisions:
netavark and aardvark-dns of the same release in `/usr/libexec/podman`, the containers-common
configuration of the release, and no gpgme, subid or sqlite linked. Nothing is compiled from a
source that upstream did not sign, except conmon and passt where a distribution has to compile
them, which publish no signature: what is trusted there is the commit a reviewer pinned (see below).

Today the rows of the table are Fedora 45 and 44, Enterprise Linux 9 and 10 (built on AlmaLinux and also proved on Rocky and on Red Hat's UBI image), Amazon Linux 2023 and openSUSE Leap 16.1 and Tumbleweed. `package-check.yml` builds them on a pull request that
changes how they are built, and each package is installed with the package manager of its
distribution (`dnf`, or `zypper` on openSUSE) on a clean image and over the distribution's own Podman,
runs containers with and without root, and is removed.

## In a release

`release.yml` builds and proves them with the same workflow (`reusable-rpm.yml`) and attaches them to the release
beside the `.deb`: every package of every distribution and architecture of the table, with its detached Ed25519
signature `<name>.sig` (and `<name>.mldsa65.sig` when the second signature is required), listed in `SHA256SUMS`,
which is signed too, and covered by the provenance attestation, signatures included. The `noarch` packages are those
of the x86_64 build. The names a release has to carry come from the table and `scripts/package/extras.txt`
(`scripts/release/rpm/names.sh`), forty packages today.

A release carries all of them or is not published: a distribution that fails stops the `.deb` as well. `components.txt`
names the distributions on its line `ids` and the packaging recipe on its line `recipe-package`, which the planner does
not compare, so a change under `scripts/package/` ships with the next release rather than starting one.

No release up to `6.2.1+r5` carries them, and no repository serves them yet.

## What a package says

- Version `X.Y.Z+rR`, always with the revision, and release `R.glyndor.<id>`. With it the package is newer
  than any build of the same Podman version that the distribution makes, whatever its release counter says,
  and older than the next Podman.
- The epoch is the one the distribution's own `podman` has (Fedora 5), because without one the package
  would be older than the distribution's at the same version and `dnf upgrade` would never replace it.
- `podman` provides and obsoletes `podman-remote`, `podman-quadlet`, `netavark`, `aardvark-dns` and, on Fedora,
  Enterprise Linux and Amazon Linux, `containers-common`, `containers-common-extra` and `skopeo-containers`
  (on openSUSE, the names that distribution gives them: `libcontainers-common`, `libcontainers-image`,
  `libcontainers-storage`, `libcontainers-policy`, `libcontainers-default-policy`, `libcontainers-openSUSE-policy`
  and `registries-conf`), and obsoletes `podman-machine` and `podman-tests`, so a host that has the
  distribution's packages upgrades without conflict and a later build of those by the distribution is not
  installed beside it. `podman-docker` and `podmansh` are built as the packages the distribution has, so a
  host that has them installed upgrades them too.
- `Vendor` is `Glyndor`, and the `Release` field ends in `.glyndor.<id>`, which says which distribution
  the file is for.

The build of each distribution lists what the distribution's repositories have that requires `podman` and fails
when one asks for an exact version or an epoch above this package's and is neither one of ours nor obsoleted.

## How a distribution is added

A row in `scripts/package/distros.txt` and an image in `scripts/package/images/<id>/Dockerfile`, pinned by
digest. The epochs and the way containers-common is numbered are read from the distribution's own
repositories, not guessed. The suites check that every row has its image and every image its row.

## The images the packages are built in

Each distribution is built and proved in an image, in `scripts/package/images/<id>/Dockerfile`. They are pinned by digest,
the digest of the index so that the arm64 runner pulls its own, and Dependabot moves the pins (one group of pull requests,
`package-images` in `.github/dependabot.yml`, reads every directory of `scripts/package/images`). AlmaLinux, Rocky and
Red Hat's UBI keep the digests they replace, so a pin there stays valid until Dependabot moves it.

Three images are not pinned by digest, and that is an exception to the rule that base images are:

- `fedora:44` and `fedora:45` on quay.io. Measured on 2026-11-24 with the tag history of the registry
  (`/api/v1/repository/fedora/fedora/tag/?specificTag=44&onlyActiveTags=false`): quay re-points `fedora:44` to a new index
  every day, between 05:56 and 07:03 UTC, and deletes the previous one in that instant. The digests of the last 14 days of
  the tag had all expired, and the manifest of the one that `main` pinned answered 404 a few hours after a build had pulled
  it. A pin by digest makes the build fail the next day, and Dependabot cannot keep up: it runs once a day, at about
  04:11 UTC, and the digest it would propose lives until about 06:00 UTC. The tag is the version (`44`, `45`), never
  `latest`, so the image is always that release.
- `opensuse/tumbleweed:latest`. Tumbleweed is rolling, so there is no release tag, and its registry stops serving the
  digests it replaces after a few days (measured on 2026-11-24: a digest taken a few days earlier was gone). The tag is
  `latest`, which is the only name a rolling distribution has.

What these images install comes from the signed repositories of the distribution, which move as well, so a digest would
fix the base layer and nothing else. The consequence is that the build of these rows is not reproducible from the
repository alone, and that a proof of one of them is a proof against the image of the day. A registry that kept the
digests of the tag would change this, and then the digest goes back. `tests/package/distros.test.sh` holds the
exception: the three ids are listed, each must carry no digest, a Fedora tag must be the version, and every other image
must carry a digest, so that nobody removes a pin where it works. It also reads the index of each tag today and fails when
it lacks amd64 or arm64; that result is the one of the day it ran.

If the pin of one of the images that do carry a digest stops resolving, `distros.test.sh` fails with "the digest pinned for
<image> is no longer in the registry. Dependabot moves it (group package-images); until it does, this suite fails here".
The fix is to merge the pull request of the group, or to take the digest of the index from
`docker buildx imagetools inspect <image>:<tag>` by hand.

## Configuration

`/etc/containers` is the administrator's, and no package puts a file under it. Podman 6.2.0 reads `containers.conf`,
`registries.conf` and `policy.json` from `/etc/containers` and, when it has none, from `/usr/share/containers`
(measured with `strace`), so the defaults of the release live there, and `seccomp.json` is read only from there. The
packages the rpm replaces own some files of `/etc/containers`, and removing a package takes its files with it: Fedora
and Enterprise Linux 10 delete an edited `containers.conf` and `storage.conf` with no copy, and Enterprise Linux 9 and
Amazon Linux 2023 save an edited `%config` file as `.rpmsave`. When the package is the first Glyndor Podman on the host,
a `%pretrans` copies each such file that is `%ghost` or reported changed by `rpm -V` aside, and a `%posttrans` puts it
back where nothing is. The proof writes all four files before the update and requires them to be the active ones after it.

## Dependencies packaged beside Podman

Where a distribution has no package Podman needs, or one that is too old, the package is built beside it from its
upstream release and takes the name of the distribution's own (`scripts/package/extras.txt`, named per distribution in the
`extras` column of the table): crun and catatonit are verified against their release signature and a key committed in
`keyring/extras/`; conmon and passt publish none, so what is trusted is the commit a reviewer pinned.

