#!/usr/bin/env bash
#
# Makes the runner a neutral host for the distributions that run on it.
#
# An unprivileged user inside a privileged container has to be able to create a user
# namespace: Ubuntu 24.04 restricts that by default, even for a process the container
# leaves unconfined.
#
# The AppArmor profiles of passt and pasta that the runner loads are matched by the path
# of the program, and that path is read inside the container too. A distribution that
# installs pasta as a symlink to passt (Arch Linux, openSUSE Leap) runs it as /usr/bin/passt,
# the profile of the socket mode attaches, and pasta cannot read its own namespace. A host
# that has the distribution installed would not carry the profiles of another one, so they
# are unloaded here, after saying which were loaded.

set -euo pipefail

sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
sudo sysctl -w kernel.unprivileged_userns_clone=1 2> /dev/null || true

echo "AppArmor profiles loaded for passt and pasta before:"
sudo aa-status 2> /dev/null | grep -E 'passt|pasta' || echo "  none"
for profile in usr.bin.passt usr.bin.pasta; do
	if [ -f "/etc/apparmor.d/$profile" ]; then
		sudo apparmor_parser -R "/etc/apparmor.d/$profile" || true
	fi
done
echo "after:"
sudo aa-status 2> /dev/null | grep -E 'passt|pasta' || echo "  none"
