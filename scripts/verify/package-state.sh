#!/usr/bin/env bash
#
# The checks of smoke-test.sh whose verdict is a reading of what a command answers:
# what the installed package left on the system, and the two answers of the network
# stack a single container cannot give. They are kept in a script of their own so a
# test can run them against answers it controls. smoke-test.sh needs root, apt and a
# clean container, and a check that cannot run anywhere else is a check nobody has
# seen fail.
#
# Usage: package-state.sh <check> [package...]
#   ships           every file a customer expects is on disk: the binaries, the helpers,
#                   the systemd units and generators, the shell completions, and the
#                   containers-common configuration, not empty (GLYNDOR_PACKAGE_ROOT
#                   puts the tree somewhere else, for tests)
#   listed          dpkg lists the man pages and /usr/bin/pasta as the package's; the
#                   minimal Ubuntu images leave /usr/share/man out of the disk
#   provides        the package provides golang-github-containers-common at 0.60 or
#                   newer, which is what buildah and skopeo depend on
#   version <v>     podman --version says <v>, the version that was built
#   seccomp         /usr/share/containers/seccomp.json is the profile of this release,
#                   the one that lists futex_waitv, and not the older one of a distribution
#                   (GLYNDOR_SECCOMP_PROFILE names another file, for tests)
#   replaced <pkg>  the distribution's <pkg> is not installed next to this package
#   kept <pkg>...   every <pkg> is still installed, as buildah and skopeo must be after
#                   the upgrade from the distribution's Podman
#   pasta-option    the pasta on PATH offers --map-guest-addr, which Podman 6.2.0 always
#                   passes and the passt of the supported releases predates
#   dns <network> <rootfs>
#                   a container on <network> finds another one by name, which is
#                   aardvark-dns: the bridge can be up and name resolution still broken
#
# Exit 0 when the check holds, 1 when it does not, 2 for a usage error.

set -euo pipefail

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }

check="${1:-}"
[ "$#" -eq 0 ] || shift
case "$check" in
	ships)
		[ "$#" -eq 0 ] || { echo "ships takes no argument" >&2; exit 2; }
		# What Debian's own package installs: if a change to the build stops shipping one
		# of these, the package still "works" and nobody notices until somebody asks why
		# tab completion was gone.
		root="${GLYNDOR_PACKAGE_ROOT:-}"
		for f in /usr/bin/podman /usr/bin/podman-remote /usr/libexec/podman/quadlet /usr/libexec/podman/rootlessport \
			/usr/lib/systemd/system/podman.socket /usr/lib/systemd/user/podman.socket \
			/usr/lib/systemd/system-generators/podman-system-generator /usr/lib/systemd/user-generators/podman-user-generator \
			/usr/lib/tmpfiles.d/podman.conf \
			/usr/share/bash-completion/completions/podman /usr/share/zsh/site-functions/_podman /usr/share/fish/vendor_completions.d/podman.fish; do
			[ -e "$root$f" ] || { echo "the package does not ship $f" >&2; exit 1; }
		done
		# The network stack is the one in the package, not Debian's.
		for helper in netavark aardvark-dns; do
			[ -x "$root/usr/libexec/podman/$helper" ] || { echo "missing $helper in the package" >&2; exit 1; }
		done
		# The configuration of the release is under /usr/share/containers and nothing is shipped in
		# /etc; the policy buildah and skopeo read from /etc/containers is copied there by postinst
		# (the smoke test's skopeo and buildah checks fail without it). A pull has the registries and
		# the short names it needs.
		for f in /usr/share/containers/policy.json /usr/share/containers/registries.conf /usr/share/containers/containers.conf \
			/usr/share/containers/registries.conf.d/000-shortnames.conf; do
			[ -s "$root$f" ] || { echo "the package does not ship $f" >&2; exit 1; }
		done ;;
	listed)
		[ "$#" -eq 0 ] || { echo "listed takes no argument" >&2; exit 2; }
		# Read whole before it is searched, so grep -q stopping early cannot send dpkg
		# the SIGPIPE that pipefail would read as a failure.
		files="$(dpkg -L podman)" || { echo "dpkg cannot list the files of podman" >&2; exit 1; }
		grep -q '^/usr/share/man/man1/podman-run\.1' <<< "$files" || { echo "the package does not ship the man pages" >&2; exit 1; }
		grep -q -x '/usr/bin/pasta' <<< "$files" || { echo "the package does not ship pasta" >&2; exit 1; } ;;
	provides)
		[ "$#" -eq 0 ] || { echo "provides takes no argument" >&2; exit 2; }
		status="$(dpkg -s podman)" || { echo "dpkg does not know podman" >&2; exit 1; }
		grep -q '^Provides:.*golang-github-containers-common (= 0\.[6-9][0-9]' <<< "$status" \
			|| { echo "the package does not provide containers-common" >&2; exit 1; } ;;
	version)
		[ "$#" -eq 1 ] || { echo "version takes the version that was built" >&2; exit 2; }
		got="$(podman --version)" || { echo "podman --version failed" >&2; exit 1; }
		[ "$got" = "podman version $1" ] || { echo "version mismatch: $got" >&2; exit 1; } ;;
	seccomp)
		[ "$#" -eq 0 ] || { echo "seccomp takes no package" >&2; exit 2; }
		grep -q '"futex_waitv"' "${GLYNDOR_SECCOMP_PROFILE:-/usr/share/containers/seccomp.json}" \
			|| { echo "the seccomp profile is not this release's" >&2; exit 1; } ;;
	replaced)
		[ "$#" -eq 1 ] || { echo "replaced takes one package" >&2; exit 2; }
		! installed "$1" || { echo "the distribution's $1 is installed next to this package" >&2; exit 1; } ;;
	kept)
		[ "$#" -ge 1 ] || { echo "kept takes at least one package" >&2; exit 2; }
		for pkg in "$@"; do
			installed "$pkg" || { echo "$pkg was removed by the upgrade" >&2; exit 1; }
		done ;;
	pasta-option)
		[ "$#" -eq 0 ] || { echo "pasta-option takes no argument" >&2; exit 2; }
		# The text is the verdict, as it was in the smoke test: the exit status of --help
		# is not, since nobody has measured it on every release. Capturing it whole also
		# spares pasta the SIGPIPE a pipe into grep -q could send it.
		help="$(pasta --help 2>&1)" || true
		[ -n "$help" ] || { echo "pasta --help printed nothing" >&2; exit 1; }
		grep -q -F -- '--map-guest-addr' <<< "$help" \
			|| { echo "pasta lacks --map-guest-addr, which Podman passes" >&2; exit 1; } ;;
	dns)
		[ "$#" -eq 2 ] || { echo "dns takes a network and a root directory" >&2; exit 2; }
		podman --storage-driver vfs run -d --name smoke-a --network "$1" --rootfs "$2" /usr/bin/sleep 120 >/dev/null \
			|| { echo "could not start a container on the network $1" >&2; exit 1; }
		found="$(podman --storage-driver vfs run --rm --network "$1" --rootfs "$2" /usr/bin/getent hosts smoke-a || true)"
		podman --storage-driver vfs rm -f smoke-a >/dev/null 2>&1 || true
		[ -n "$found" ] || { echo "a container on the bridge network could not resolve another by name" >&2; exit 1; } ;;
	*)
		echo "usage: package-state.sh ships | listed | provides | version <version> | seccomp | replaced <package> | kept <package>... | pasta-option | dns <network> <rootfs>" >&2
		exit 2 ;;
esac
