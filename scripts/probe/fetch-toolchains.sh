#!/usr/bin/env bash
#
# Download the official Go and Rust installers on the runner and check them against the
# checksums their publishers list, for a distribution whose own toolchain is too old.
# Go: the newest release of the minor version Podman's go.mod asks for, with the sha256
# go.dev lists for that file. Rust: rustup-init, with the .sha256 file next to it.
#
# The protobuf compiler of its latest release, with the digest GitHub lists for the asset,
# for a distribution whose repositories carry none (netavark needs protoc to build).
#
# Usage: fetch-toolchains.sh <directory> <podman source dir>   (GH_TOKEN set)

set -euo pipefail
dest="$(mkdir -p "${1:?directory}" && cd "$1" && pwd)"
need="$(awk '$1 == "go" {print $2; exit}' "${2:?podman source dir}/go.mod")"
minor="${need%.*}"

curl -fsSL --retry 3 'https://go.dev/dl/?mode=json&include=all' -o "$dest/go-releases.json"
file="$(jq -r --arg m "go$minor." '[.[] | select(.stable and (.version | startswith($m)))][0].files[]
	| select(.os == "linux" and .arch == "amd64" and .kind == "archive") | .filename' "$dest/go-releases.json")"
sum="$(jq -r --arg f "$file" '.[].files[] | select(.filename == $f) | .sha256' "$dest/go-releases.json" | head -n 1)"
if [ -z "$file" ] || [ -z "$sum" ]; then
	echo "go.dev lists no linux amd64 archive for go $minor" >&2
	exit 1
fi
curl -fsSL --retry 3 -o "$dest/$file" "https://go.dev/dl/$file"
echo "$sum  $dest/$file" | sha256sum -c -
rm "$dest/go-releases.json"

url=https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
curl -fsSL --retry 3 -o "$dest/rustup-init" "$url"
curl -fsSL --retry 3 -o "$dest/rustup-init.sha256" "$url.sha256"
(cd "$dest" && sha256sum -c rustup-init.sha256)
chmod 0755 "$dest/rustup-init"

asset="$(gh release view --repo protocolbuffers/protobuf --json assets \
	-q '.assets[] | select(.name | test("^protoc-[0-9.]+-linux-x86_64[.]zip$")) | [.name, .digest, .url] | @tsv')"
IFS=$'\t' read -r name digest url <<< "$asset"
case "$digest" in sha256:*) ;; *) echo "GitHub lists no sha256 for the protoc release asset" >&2; exit 1 ;; esac
curl -fsSL --retry 3 -o "$dest/$name" "$url"
echo "${digest#sha256:}  $dest/$name" | sha256sum -c -
mkdir -p "$dest/protoc"
unzip -q -o "$dest/$name" -d "$dest/protoc"
rm "$dest/$name"
