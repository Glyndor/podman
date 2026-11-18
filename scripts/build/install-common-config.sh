#!/usr/bin/env bash
#
# Install the containers-common configuration this Podman release asks for, so the
# package does not depend on the older one a distribution ships. Podman 6.2.0's spec
# requires containers-common 0.68 or newer ("Podman 6 requires the new config file
# layout") and the release is built with common 0.70, while Debian 13, Ubuntu 24.04
# and Ubuntu 26.04 carry 0.62, 0.57 and 0.66.
#
# The files come from the Go modules the signed Podman tag pins: `go mod download`
# checks each module against the go.sum of that tag, so the chain is the tag's
# signature, then go.sum, then the files. The layout and the file list follow
# common's own containers-common.spec, minus what is Fedora's or Red Hat's own
# (their registries, sigstore keys, the mounts of a subscription, runtime and
# storage vendor drop-ins), and without storage.conf: Debian's containers-storage
# owns it, and it only restates the defaults compiled into Podman. The short-name list is the one Debian ships, taken
# from its signed archive by the build image: upstream's spec fetches the head of
# a branch with no signature.
#
# Prints the version of common that was installed.
#
# Usage: install-common-config.sh <podman-src> <stage-dir> <shortnames.conf>
#   GLYNDOR_MODULES_DIR=<dir with the common and image trees> skips the download (tests).

set -euo pipefail

src="$(cd "${1:?podman source dir}" && pwd)"
stage="${2:?stage dir}"
shortnames="${3:?shortnames.conf}"
[ -s "$shortnames" ] || { echo "no short-name list at $shortnames" >&2; exit 1; }

module_version() { # <module path> -> version without the v
	awk -v m="$1" '$1 == m {sub(/^v/, "", $2); print $2; exit}' "$src/go.mod"
}

fetch() { # <module path> <version> -> prints the directory with the module's files
	if [ -n "${GLYNDOR_MODULES_DIR:-}" ]; then
		local name="${1%/v[0-9]*}"
		echo "$GLYNDOR_MODULES_DIR/${name##*/}"
		return
	fi
	# Run from the Podman tree so go.sum is the one that verifies the module.
	(cd "$src" && GOFLAGS=-mod=mod go mod download -json "$1@v$2" | awk -F'"' '/"Dir":/ {print $4}')
}

common_version="$(module_version go.podman.io/common)"
image_version="$(module_version go.podman.io/image/v5)"
for v in "$common_version" "$image_version"; do
	[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cannot read the containers modules from $src/go.mod" >&2; exit 1; }
done

common="$(fetch go.podman.io/common "$common_version")"
image="$(fetch go.podman.io/image/v5 "$image_version")"

share="$stage/usr/share/containers"
put() { # <source> <destination under share>
	[ -s "$1" ] || { echo "the module has no $1" >&2; exit 1; }
	install -D -m 0644 "$1" "$share/$2"
}
put "$common/pkg/config/containers.conf" containers.conf
put "$common/pkg/seccomp/seccomp.json" seccomp.json
put "$common/rpm/policy.json" policy.json
put "$image/registries.conf" registries.conf
put "$image/default.yaml" registries.d/default.yaml
put "$shortnames" registries.conf.d/000-shortnames.conf

# The directories the spec owns; Podman and its users drop their own files in them.
for d in etc/containers/certs.d etc/containers/networks etc/containers/oci/hooks.d \
	etc/containers/registries.conf.d etc/containers/registries.d etc/containers/systemd \
	usr/share/containers/containers.conf.d usr/share/containers/storage.conf.d \
	usr/share/containers/storage.rootful.conf.d usr/share/containers/storage.rootless.conf.d; do
	install -d -m 0755 "$stage/$d"
done

echo "$common_version"
