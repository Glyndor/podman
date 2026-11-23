#!/usr/bin/env bash
#
# Step 3: install what step 2 built into /usr, and the containers-common configuration
# of the release with the script the Debian package uses. Exit 3 when a component did not
# build: there is nothing to install and the later steps are skipped.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
repo="$(cd "$here/../.." && pwd)"

for c in podman netavark aardvark-dns; do
	grep -q "^build.$c	ok$" "$PROBE_OUT/facts.tsv" 2> /dev/null || { echo "$c was not built"; exit 3; }
done

export GOTOOLCHAIN=local
status=0
for src in podman netavark aardvark-dns; do
	if ! make -C "$PROBE_SRC/$src" install PREFIX=/usr; then
		fail "make install of $src failed"
		status=1
	fi
done

# The short-name list: the Debian build takes the one of Debian's signed archive. Here
# there is no such archive, so the head of the upstream list is used, which is what
# upstream's own spec does and is the one thing here that is not verified.
shortnames="$PROBE_OUT/shortnames.conf"
curl -fsSL --retry 3 -o "$shortnames" https://raw.githubusercontent.com/containers/shortnames/main/shortnames.conf \
	|| { fail "cannot fetch the short-name list"; status=1; }
common_version="$(bash "$repo/scripts/build/install-common-config.sh" "$PROBE_SRC/podman" / "$shortnames")" \
	|| { fail "install-common-config.sh failed"; status=1; }
fact install.containers-common "${common_version:-none}"

got="$(podman --version 2>&1)" || true
fact install.podman "$got"
fact install.netavark "$(/usr/libexec/podman/netavark --version 2>&1 | head -n 1)"
fact install.aardvark-dns "$(/usr/libexec/podman/aardvark-dns --version 2>&1 | head -n 1)"
[ "$got" = "podman version ${PODMAN_TAG#v}" ] || { fail "podman says '$got', expected ${PODMAN_TAG#v}"; status=1; }
if [ "$status" -eq 0 ]; then fact install ok; else fact install fail; fi
exit "$status"
