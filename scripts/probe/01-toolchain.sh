#!/usr/bin/env bash
#
# Step 1: the compiler, the headers and the tools the three builds need. The Go and the
# Rust of the distribution are used when they are new enough for the tags being built;
# when they are not, the official toolchain the runner downloaded and checked takes
# their place, so the rest of the build can still be measured, and the result says which
# one was used and what the distribution had.

set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# A command that stops the step under set -e names itself, so the result quotes it.
trap 'fail "stopped at line $LINENO: $BASH_COMMAND"' ERR

pm_refresh

case "$PM" in
	dnf)
		required=(gcc make git-core pkgconf-pkg-config tar xz gzip findutils diffutils which file python3
			glibc-devel libseccomp-devel systemd-devel protobuf-compiler)
		optional=(libselinux-devel btrfs-progs-devel shadow-utils util-linux)
		go_pkg=golang
		rust_pkgs=(rust cargo) ;;
	zypper)
		required=(gcc make git-core pkgconf-pkg-config tar xz gzip findutils diffutils which file gawk
			glibc-devel libseccomp-devel systemd-devel protobuf-devel)
		optional=(libselinux-devel libbtrfs-devel shadow util-linux)
		go_pkg=go
		rust_pkgs=(rust cargo) ;;
	pacman)
		required=(base-devel git pkgconf libseccomp systemd protobuf)
		optional=(libselinux btrfs-progs shadow util-linux)
		go_pkg=go
		rust_pkgs=(rust) ;;
esac
pm_install "${required[@]}"
if ! command -v curl > /dev/null; then pm_install curl; fi
missing="$(pm_try "${optional[@]}" | paste -sd' ')"
fact toolchain.headers-missing "${missing:-none}"
fact os.pretty "$PRETTY_NAME"
fact os.kernel "$(uname -r)"
fact os.arch "$(uname -m)"
git config --global --add safe.directory '*'

# Go: the version go.mod of Podman asks for, with the toolchain switch off so the answer
# is about this machine and not about the module proxy.
need_go="$(awk '$1 == "go" {print $2; exit}' "$PROBE_SRC/podman/go.mod")"
[ -n "$need_go" ] || { fail "cannot read the Go version from go.mod of Podman"; exit 1; }
export GOTOOLCHAIN=local
have_go=""
if pm_install "$go_pkg" > "$PROBE_OUT/logs/pm-go.log" 2>&1 && command -v go > /dev/null; then
	have_go="$(go env GOVERSION | sed 's/^go//')"
fi
if ver_ge "$have_go" "$need_go"; then
	fact toolchain.go "distribution: go $have_go (asks for $need_go)"
else
	tar_go="$(ls "$PROBE_TOOLS"/go*.linux-*.tar.gz)"
	tar -C /opt -xzf "$tar_go"
	use_path /opt/go/bin
	fact toolchain.go "official go.dev: $(go version | awk '{print $3}'), sha256 checked by the runner; distribution has ${have_go:-none} (asks for $need_go)"
fi
go version

# Rust: the newest rust-version of netavark and aardvark-dns.
need_rust="$(for r in netavark aardvark-dns; do
	awk -F'"' '/^rust-version/ {print $2}' "$PROBE_SRC/$r/Cargo.toml"
done | sort -V | tail -n 1)"
[ -n "$need_rust" ] || { fail "cannot read rust-version from Cargo.toml"; exit 1; }
have_rust=""
# shellcheck disable=SC2046
if pm_install "${rust_pkgs[@]}" > "$PROBE_OUT/logs/pm-rust.log" 2>&1 && command -v rustc > /dev/null; then
	have_rust="$(rustc --version | awk '{print $2}')"
fi
if ver_ge "$have_rust" "$need_rust"; then
	fact toolchain.rust "distribution: rustc $have_rust (asks for $need_rust)"
else
	export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo RUSTUP_INIT_SKIP_PATH_CHECK=yes
	"$PROBE_TOOLS/rustup-init" -y --profile minimal --default-toolchain stable --no-modify-path
	printf 'export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo\n' >> "$PROBE_ENV"
	use_path /opt/cargo/bin
	fact toolchain.rust "official rustup, stable: rustc $(rustc --version | awk '{print $2}'), rustup-init sha256 checked by the runner; distribution has ${have_rust:-none} (asks for $need_rust)"
fi
rustc --version
cargo --version
protoc --version || { fail "no protoc: netavark needs the protobuf compiler to build"; exit 1; }
