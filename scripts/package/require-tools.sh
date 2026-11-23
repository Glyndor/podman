#!/usr/bin/env bash
#
# Refuse a build container that lacks a program the build runs, and say which, before anything is
# compiled: the list is scripts/package/build-tools.txt. A tool that is missing otherwise shows up
# an hour in as "env: 'python3': No such file or directory" from the middle of make.
#
# Usage: require-tools.sh <rpm|pacman>
# GLYNDOR_TOOLS_FILE names another list, for tests.

set -euo pipefail

format="${1:?rpm or pacman}"
case "$format" in rpm | pacman) ;; *) echo "the format is rpm or pacman, not $format" >&2; exit 2 ;; esac
list="${GLYNDOR_TOOLS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-tools.txt}"
[ -f "$list" ] || { echo "no list of build tools at $list" >&2; exit 1; }

missing=""
while read -r tool formats; do
	case "$tool" in '' | '#'*) continue ;; esac
	if [ -n "$formats" ] && [ " $formats " != " $format " ]; then continue; fi
	command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
done < "$list"
[ -z "$missing" ] || { echo "this build container lacks:$missing; install them in the build dependencies of scripts/package/ before building" >&2; exit 1; }
echo "every program the build runs is here"
