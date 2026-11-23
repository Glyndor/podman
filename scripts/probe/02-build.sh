#!/usr/bin/env bash
#
# Step 2: build Podman, netavark and aardvark-dns from the verified tags, the way
# scripts/build/build-deb.sh builds them for Debian: the same flags and the same Go
# build tags, so a difference in the result comes from the distribution. Each
# component is built even when another one failed, so one run says which of them
# the distribution can build.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

export GOTOOLCHAIN=local
export GOFLAGS="-trimpath -buildmode=pie"
case "$(uname -m)" in
	x86_64) flow_protection="-fcf-protection=full" ;;
	aarch64) flow_protection="-mbranch-protection=standard" ;;
	*) flow_protection="" ;;
esac
export CGO_CFLAGS="-O2 -g $flow_protection -D_FORTIFY_SOURCE=2"
export CGO_LDFLAGS="-Wl,-z,relro -Wl,-z,now"
SOURCE_DATE_EPOCH="$(git -C "$PROBE_SRC/podman" log -1 --format=%ct 2> /dev/null || date +%s)"
export SOURCE_DATE_EPOCH

status=0
build() { # <fact name> <log name> <command...>
	local name="$1" log="$PROBE_OUT/logs/build-$2.log"
	shift 2
	if "$@" > "$log" 2>&1; then
		fact "build.$name" ok
	else
		fact "build.$name" fail
		cat "$log"
		fail "$name did not build"
		status=1
	fi
}

build podman podman make -C "$PROBE_SRC/podman" PREFIX=/usr EXTRA_BUILDTAGS=containers_image_openpgp \
	BUILD_INFO="$SOURCE_DATE_EPOCH" BUILD_ORIGIN="Glyndor"
# Podman's Makefile builds go-md2man from its own vendor tree; the manual pages of the two
# Rust components are built with it.
if [ -x "$PROBE_SRC/podman/test/tools/build/go-md2man" ]; then
	install -m 0755 "$PROBE_SRC/podman/test/tools/build/go-md2man" /usr/local/bin/go-md2man
fi
build netavark netavark make -C "$PROBE_SRC/netavark" CARGO="cargo --locked"
build aardvark-dns aardvark make -C "$PROBE_SRC/aardvark-dns" CARGO="cargo --locked"
exit "$status"
