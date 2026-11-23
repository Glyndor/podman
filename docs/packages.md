# Native packages

Besides the `.deb`, this repository builds Podman as an rpm or a pacman package for the distributions listed in
[`scripts/package/distros.txt`](../scripts/package/distros.txt): Fedora 45 and 44, AlmaLinux, Rocky Linux and RHEL 9 and 10
(one package per major version, built on AlmaLinux and also proved on Rocky and on Red Hat's UBI image), Amazon Linux 2023,
openSUSE Leap 16.1 and Tumbleweed, and Arch Linux (x86_64 only: Arch has no official aarch64 port). They are built from the same three upstream
tags as the `.deb`, whose signatures are verified the same way, and they carry the same decisions:
netavark and aardvark-dns of the same release in `/usr/libexec/podman`, the containers-common
configuration of the release, and no gpgme, subid or sqlite linked. Nothing is compiled from a
source that upstream did not sign.

`package-check.yml` builds all of them on a pull request that
changes how they are built, and each package is installed with the package manager of the distribution on a clean image and over the
distribution's own Podman, runs containers with and without root, and is removed. Release runs do not publish
them yet.

Where a distribution has no package Podman needs, or one that is too old, the package is built beside it from its
upstream release and takes the name of the distribution's own (`scripts/package/extras.txt`): crun and catatonit are
verified against their release signature and a key committed in `keyring/extras/`; conmon and passt publish none, so what
is trusted is the commit a reviewer pinned.

## What a package says

- On Arch the package replaces `netavark`, `aardvark-dns` and `containers-common` with `replaces`, which acts in a
  system upgrade only: the command is `pacman -Syu --needed podman`, and `pacman -Sy podman` stops on a conflict.
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
