#!/usr/bin/env bash
#
# Fail when Arch has a package that requires podman in a way the package of this repository
# cannot satisfy and does not replace: a package that needs podman at an exact version, or at an
# epoch. The package replaces netavark, aardvark-dns and containers-common and splits
# podman-docker like Arch does, which is what is covered; anything else that asks for podman by
# an exact version would stop the update of a host that has it.
#
# Every query is an assignment of its own, so a pacman that fails stops the script, and an empty
# list of what requires podman is refused because podman-docker is known to.
#
# Usage: check-replacement.sh

set -euo pipefail

covered=" podman-docker "
info="$(pacman -Sii podman)" || { echo "cannot ask the repositories about podman" >&2; exit 1; }
line="$(printf '%s\n' "$info" | grep -E '^Required By' || true)"
[ -n "$line" ] || { echo "the repositories say nothing of what requires podman, so the answer cannot be trusted" >&2; exit 1; }
requirers="$(printf '%s\n' "${line#*:}" | tr -s ' ' '\n' | grep -v -e '^$' -e '^None$' || true)"
printf '%s\n' "$requirers" | grep -q -x podman-docker \
	|| { echo "the repositories do not list podman-docker among what requires podman, so the answer cannot be trusted" >&2; exit 1; }

bad=""
for pkg in $requirers; do
	case "$covered" in *" $pkg "*) continue ;; esac
	pinfo="$(pacman -Si "$pkg")" || { echo "cannot ask the repositories about $pkg" >&2; exit 1; }
	deps="$(printf '%s\n' "$pinfo" | grep -E '^Depends On' || true)"
	for dep in ${deps#*:}; do
		case "$dep" in
			podman=*) bad="$bad$pkg requires podman exactly (${dep#podman=})\n" ;;
			podman'>='[0-9]*:*) bad="$bad$pkg requires podman at an epoch (${dep#podman>=})\n" ;;
		esac
	done
done
if [ -n "$bad" ]; then
	printf '%b' "$bad" >&2
	echo "Arch has packages that this one neither satisfies nor replaces; cover them before building" >&2
	exit 1
fi
echo "every package of Arch that requires podman is satisfied or replaced"
