#!/usr/bin/env bash
#
# Make the metadata of a repository of rpm files with createrepo_c, in the container of the distribution
# the package was built in, and write it where the proof can read it: <out>/repodata. The proof then puts
# the same files and that metadata in a repository the package manager of each image reads, so the image of
# Red Hat's UBI, whose repositories do not have createrepo_c and which has no EPEL, proves the same thing
# the others do: that the package manager reads a repository and installs from it. Run as root, in the
# build container, with network access to the repositories of the distribution, which are signed.
#
# Usage: make-repo.sh <directory with the .rpm files> <directory for repodata>

set -euo pipefail

in="${1:?directory with the rpm files}"
out="${2:?directory for repodata}"
[ -d "$in" ] || { echo "$in is not a directory" >&2; exit 1; }
[ -d "$out" ] || { echo "$out is not a directory" >&2; exit 1; }
compgen -G "$in/*.rpm" > /dev/null || { echo "no .rpm file in $in" >&2; exit 1; }

if command -v zypper > /dev/null 2>&1; then
	zypper --non-interactive install --no-recommends createrepo_c
else
	dnf install -y createrepo_c
fi
createrepo_c --outputdir "$out" "$in"
[ -f "$out/repodata/repomd.xml" ] || { echo "createrepo_c wrote no repodata/repomd.xml in $out" >&2; exit 1; }
echo "repository metadata of $(find "$in" -maxdepth 1 -name '*.rpm' | wc -l) packages written to $out/repodata"
