# Verifying a package

Each release publishes `podman_<version>_<arch>.deb` and `podman_<version>_<arch>.deb.sig`, an Ed25519 signature made with the Glyndor release key. The public key is in [`keyring/glyndor-release-ed25519.b64`](../keyring/glyndor-release-ed25519.b64).

Releases also carry a build provenance attestation:

```bash
gh attestation verify podman_<version>_<arch>.deb --repo Glyndor/podman
```

`apt` verifies the archive signature automatically, so this is only needed when downloading a package by hand.
