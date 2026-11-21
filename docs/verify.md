# Verifying a package

Each release publishes `podman_<version>_<arch>.deb` and `podman_<version>_<arch>.deb.sig`, an Ed25519 signature made with the Glyndor release key, plus a `components.txt` that lists the upstream versions it was built from. The public key is in [`keyring/glyndor-release-ed25519.b64`](../keyring/glyndor-release-ed25519.b64).

`apt` verifies the archive signature automatically, so this is only needed when downloading a package by hand. There are two independent checks.

## Check the signature with OpenSSL

You need OpenSSL 3 and `curl`. The key file holds a raw 32-byte Ed25519 public key in base64. OpenSSL reads a PEM key, so the steps below wrap the raw key in the standard 12-byte DER header (`302a300506032b6570032100`, which is `MCowBQYDK2VwAyEA` in base64). Set `version` and `arch` to the release you downloaded, for example `6.2.0+r8` and `amd64`:

```bash
version='6.2.0+r8'; arch=amd64
deb="podman_${version}_${arch}.deb"

# the key from this repository, as a PEM file
key="$(curl -sSf https://raw.githubusercontent.com/Glyndor/podman/main/keyring/glyndor-release-ed25519.b64)"
{ echo '-----BEGIN PUBLIC KEY-----'
  printf 'MCowBQYDK2VwAyEA%s=\n' "$key"
  echo '-----END PUBLIC KEY-----'; } > glyndor-release.pem

# the release assets; a literal + in a tag is %2B in the URL
base="https://github.com/Glyndor/podman/releases/download/v${version/+/%2B}"
curl -sSfLO "$base/$deb" -O "$base/$deb.sig"

openssl pkeyutl -verify -pubin -inkey glyndor-release.pem -rawin -in "$deb" -sigfile "$deb.sig"
```

A good package prints `Signature Verified Successfully` and exits with status 0. A package that was changed by even one byte prints `Signature Verification Failure` and exits with status 1; do not install it.

The key is read from this repository, so this proves the package was signed by whoever holds the private key that matches it. To pin the key independently of GitHub, copy the file once and compare it against a copy you obtained from another channel.

## Check the build provenance

Releases also carry a build provenance attestation, which says which workflow run of this repository built the package:

```bash
gh attestation verify "$deb" --repo Glyndor/podman
```
