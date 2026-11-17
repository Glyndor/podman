# podman-deb

Signed Podman packages for Debian 13, built from the latest stable upstream releases.

[![release](https://github.com/Glyndor/podman-deb/actions/workflows/release.yml/badge.svg)](https://github.com/Glyndor/podman-deb/actions/workflows/release.yml)

Debian 13 ships Podman 5.4 with netavark 1.14, which is too old for current Podman. This repository packages the newest stable Podman together with the netavark and aardvark-dns it needs as one `.deb` for `amd64` and `arm64`, so a Debian 13 host can run the current release and receive its fixes through `apt`.

## Install

The package is served from the Glyndor apt repository. See [apt.glyndor.net](https://apt.glyndor.net) for setup, then:

```bash
sudo apt install podman
```

Because the Glyndor version is newer than Debian's, `apt` prefers it once the repository is configured.

## How a release is made

```mermaid
flowchart LR
  A[Upstream stable tags] --> B[Verify tag signatures]
  B --> C[Build on Debian 13]
  C --> D[Install and run on clean Debian 13]
  D --> E[Sign the package]
  E --> F[GitHub release]
  F --> G[apt.glyndor.net]
```

- A scheduled workflow looks for the newest stable tag of `containers/podman`, `containers/netavark` and `containers/aardvark-dns` every six hours. Pre-releases are ignored. A new tag of any of the three starts a release.
- Each tag must be an annotated tag signed by a key listed in [containers/release-keys](https://github.com/containers/release-keys); the keys are kept in `keyring/podman/`. An unsigned, expired or unknown signature stops the run.
- The package is built from the official sources with the upstream `make` targets. Rust comes from Debian's own `trixie-backports`.
- Before signing, the package is installed on a clean Debian 13 and runs a container.
- If any step fails nothing is published, and the previous release remains the latest.

Each release carries one `.deb` and one detached `.sig` per architecture. Verification instructions are in [docs/verify.md](docs/verify.md).

## Scope

The package replaces Debian's `netavark` and `aardvark-dns`. Other dependencies such as `conmon`, `crun` and `passt` come from Debian. Release versions follow Podman's (`6.2.0`), with a `+rN` suffix when netavark or aardvark-dns change under the same Podman. Report Podman bugs to [containers/podman](https://github.com/containers/podman).

## License

[MIT](LICENSE) for the packaging scripts. Podman is licensed under Apache-2.0 by its authors.
