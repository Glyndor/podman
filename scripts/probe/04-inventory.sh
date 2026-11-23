#!/usr/bin/env bash
#
# Step 4: what Podman needs at run time and what the distribution offers of it. The
# version is read from the repositories without installing, compared with what Podman
# 6.2.0 asks for, and written down as ok, short or missing. What is ok is installed for
# the start-up tests; what is short or missing is what a package would have to carry,
# and 04b-short-deps.sh builds the two that can be built from source.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

# <name> <package here> <needed, empty for any> <date: passt snapshot>
deps=(
	"crun crun 1.21"
	"conmon conmon 2.1.7"
	"passt passt 20260716 date"
	"catatonit catatonit"
	"fuse-overlayfs fuse-overlayfs"
	"nftables nftables"
	"containers-common containers-common 0.68.0"
	"runc runc"
	"netavark netavark"
	"aardvark-dns aardvark-dns"
	"podman podman"
)
case "$PM" in
	dnf) shadow="shadow-utils" ;;
	*) shadow=shadow ;;
esac
deps+=("newuidmap $shadow")

install_now=()
for d in "${deps[@]}"; do
	read -r name pkg need kind <<< "$d"
	raw="$(pm_version "$pkg")"
	have="$(upstream_version "$raw" "${kind:-}")"
	if [ -z "$raw" ]; then
		verdict=missing
	elif [ "$name" = containers-common ] && [ "${have%%.*}" != 0 ]; then
		# RHEL numbers its containers-common with the Podman it ships (6.1), not with
		# upstream's 0.70, so the two cannot be compared. It is not a verdict on the content.
		verdict=other-scheme
	elif [ -z "$need" ] || ver_ge "$have" "$need"; then
		verdict=ok
	else
		verdict=short
	fi
	fact "dep.$name" "${have:-none}|${need:-any}|$verdict|$pkg ${raw:-}"
	echo "$name: distribution has ${raw:-nothing} (needs ${need:-any}): $verdict"
	# Installed for the tests: what is not the engine itself, not replaced by a build of
	# this probe (netavark, aardvark-dns, podman) and not a package the Debian build
	# also leaves to its own files (containers-common).
	case "$name" in
		netavark | aardvark-dns | podman | containers-common) ;;
		runc) ;;
		*) [ "$verdict" != ok ] || install_now+=("$pkg") ;;
	esac
done

if [ "${#install_now[@]}" -gt 0 ]; then
	failed="$(pm_try "${install_now[@]}" | paste -sd' ')"
	fact install.runtime-deps "${install_now[*]}; not installable: ${failed:-none}"
fi
# runc is the alternative to a crun that is not there or too old.
runc_failed="$(pm_try runc | paste -sd' ')"
fact install.runc "${runc_failed:+not installable}"
