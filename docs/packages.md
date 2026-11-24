# Native packages

Besides the `.deb`, this repository builds Podman as an rpm for the distributions listed in
[`scripts/package/distros.txt`](../scripts/package/distros.txt). They are built from the same three upstream
tags as the `.deb`, whose signatures are verified the same way, and they carry the same decisions:
netavark and aardvark-dns of the same release in `/usr/libexec/podman`, the containers-common
configuration of the release, and no gpgme, subid or sqlite linked. Nothing is compiled from a
source that upstream did not sign.

Today the rows of the table are Fedora 45 and 44, Enterprise Linux 10 (built on AlmaLinux and also proved on Rocky and on Red Hat's UBI image) and openSUSE Tumbleweed. `package-check.yml` builds them on a pull request that
changes how they are built, and each package is installed with `dnf` on a clean image and over the
Fedora Podman, runs containers with and without root, and is removed. Release runs do not publish
them yet.

## What a package says

- Version `X.Y.Z+rR`, always with the revision, and release `R.glyndor.<id>`. With it the package is newer
  than any build of the same Podman version that the distribution makes, whatever its release counter says,
  and older than the next Podman.
- The epoch is the one the distribution's own `podman` has (Fedora 5), because without one the package
  would be older than the distribution's at the same version and `dnf upgrade` would never replace it.
- `podman` provides and obsoletes `podman-remote`, `podman-quadlet`, `netavark`, `aardvark-dns`,
  `containers-common`, `containers-common-extra` and `skopeo-containers`, and obsoletes `podman-machine` and `podman-tests`, so a host that has the
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

Each distribution is built and proved in an image pinned by digest, in `scripts/package/images/<id>/Dockerfile`. Dependabot
moves those pins by itself, in one group of pull requests (`package-images` in `.github/dependabot.yml`) that reads every
directory of `scripts/package/images`. A pin has to be moved because the registries stop serving the digests they replace:
Tumbleweed is rolling, its tag is `latest` and its digest changes every day or two, and `fedora:44` and `fedora:45` are
rebuilt and re-tagged often (the digests of both were gone from quay.io on the day they were measured, a few hours after
a build had pulled them). An image whose digest is gone cannot be pulled, so every build of that row fails at its first
step. The check that fails first is `tests/package/distros.test.sh`, with "the digest pinned for <image> is no longer in
the registry. Dependabot moves it (group package-images); until it does, this suite fails here". The fix is to merge the
pull request of the group, or to take the digest of the index from
`docker buildx imagetools inspect <image>:<tag>` by hand. The images of Enterprise Linux (AlmaLinux, Rocky, UBI) change less
often, and their digests stay in the registry longer.

## Configuration

`/etc/containers` is the administrator's, and no package puts a file under it. Podman 6.2.0 reads `containers.conf`,
`registries.conf` and `policy.json` from `/etc/containers` and, when it has none, from `/usr/share/containers`
(measured with `strace`), so the defaults of the release live there, and `seccomp.json` is read only from there. The
packages the rpm replaces own some files of `/etc/containers`, and removing a package takes its files with it: Fedora
and Enterprise Linux 10 delete an edited `containers.conf` and `storage.conf` with no copy, and Enterprise Linux 9 and
Amazon Linux 2023 save an edited `%config` file as `.rpmsave`. When the package is the first Glyndor Podman on the host,
a `%pretrans` copies each such file that is `%ghost` or reported changed by `rpm -V` aside, and a `%posttrans` puts it
back where nothing is. The proof writes all four files before the update and requires them to be the active ones after it.

