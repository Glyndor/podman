#!/usr/bin/env bash
#
# Prints the GitHub owner and name of an upstream component: the one place that says where each lives.
# Podman moved to podman-container-tools/podman (containers/podman redirects there, measured 2026-11-23);
# netavark and aardvark-dns are still under containers.
#
# Usage: repo.sh podman|netavark|aardvark-dns
set -eu

case "${1:-}" in
	podman) echo podman-container-tools/podman ;;
	netavark | aardvark-dns) echo "containers/$1" ;;
	*) echo "unknown upstream component: ${1:-}" >&2; exit 2 ;;
esac
