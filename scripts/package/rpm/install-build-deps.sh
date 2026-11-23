#!/usr/bin/env bash
#
# Install what the build of the native rpm needs into the build container of a distribution:
# the compiler of the distribution, the headers Podman links, and rpmbuild. Run as root, in
# the container, with network access to the repositories of the distribution, which are
# signed: nothing is fetched from anywhere else.
#
# The headers of btrfs are installed when the distribution has them (the EL family left
# btrfs out), and the build takes the btrfs tag only when they are there; every other
# package is required, and one the repositories lack stops the build here and says which.
#
# Usage: install-build-deps.sh <family>      family: fedora, el, amzn or suse

set -euo pipefail

family="${1:?family}"

case "$family" in
	fedora | el | amzn)
		install=(dnf install -y --setopt=install_weak_deps=False)
		required=(rpm-build gcc make git-core pkgconf-pkg-config golang cargo rust glibc-devel
			libseccomp-devel systemd-devel libselinux-devel protobuf-compiler gettext python3
			file binutils findutils which tar xz gzip shadow-utils
			man-db perl-interpreter gawk sed grep)
		optional=(btrfs-progs-devel) ;;
	suse)
		install=(zypper --non-interactive install --no-recommends)
		required=(rpm-build gcc make git-core pkgconf-pkg-config go cargo rust glibc-devel
			libseccomp-devel systemd-devel libselinux-devel protobuf-devel gettext-runtime python3
			file binutils findutils which tar xz gzip shadow
			man perl gawk sed grep)
		optional=(libbtrfs-devel) ;;
	*) echo "no build dependencies are known for the family: $family" >&2; exit 2 ;;
esac

case "$family" in
	el)
		# The headers of the RHEL family are in a repository that is off by default, called
		# crb or codeready-builder depending on the clone. It is a build-time repository:
		# nothing installed from it is a run-time dependency of the package.
		dnf install -y dnf-plugins-core
		for repo in $(dnf repolist --all | awk '$1 ~ /(^crb$|codeready)/ {print $1}'); do
			dnf config-manager --set-enabled "$repo"
		done ;;
	suse) zypper --non-interactive --gpg-auto-import-keys refresh ;;
esac

"${install[@]}" "${required[@]}" \
	|| { echo "the repositories of this distribution lack a package the build requires: ${required[*]}" >&2; exit 1; }
for pkg in "${optional[@]}"; do
	"${install[@]}" "$pkg" || echo "no $pkg here: the build goes without btrfs" >&2
done
# What the build runs has to be there now, not found in the middle of make.
bash "$(dirname "${BASH_SOURCE[0]}")/../require-tools.sh" rpm
