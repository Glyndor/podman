#!/usr/bin/env bash
#
# Say whether a pull request has to build the native packages (rpm, pacman). It reads the
# paths the pull request changes, one per line, on stdin and prints "true" or "false".
#
# "true" when a path is something the packages are built from or checked with: everything
# under scripts/package/, the scripts they call (the upstream scripts, the configuration
# installer of scripts/build and the checks of scripts/verify/package-state.sh), the scripts
# that stage and gather them (scripts/release/rpm/ and the check of an upload they share with the
# release, scripts/release/check-upload.sh), the keys that verify upstream tags, the
# three workflows that run the build, the release workflow, and this script. The .deb has its
# own check, build-check.yml, and the scripts of scripts/build change it, not these packages,
# except the one that installs the containers-common configuration.
#
# It fails open: an empty or unreadable list, or a path git printed quoted, prints "true".
# The workflow reads this file from the base commit, so a pull request cannot rewrite it to
# skip its own build.
#
# Usage: git diff --name-only <base> <head> | decide-package.sh

set -u

list="$(cat 2>/dev/null)" || { echo true; exit 0; }

seen=0
while IFS= read -r path; do
	[ -n "$path" ] || continue
	seen=1
	path="${path#./}"
	case "$path" in
		scripts/package/* | scripts/upstream/* | scripts/verify/package-state.sh \
			| scripts/build/install-common-config.sh | keyring/podman/* \
			| scripts/release/rpm/* | scripts/release/check-upload.sh \
			| .github/workflows/reusable-package.yml \
			| .github/workflows/reusable-rpm.yml \
			| .github/workflows/package-check.yml \
			| .github/workflows/release.yml \
			| scripts/ci/decide-package.sh)
			echo true; exit 0 ;;
		\"*) echo true; exit 0 ;;
	esac
done <<< "$list"

[ "$seen" -eq 1 ] || { echo true; exit 0; }
echo false
