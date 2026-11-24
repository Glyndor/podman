#!/usr/bin/env bash
#
# Make the hosted runner a neutral host for the containers of the distributions that run on it.
#
# An unprivileged user inside a privileged container has to be able to create a user namespace,
# and Ubuntu restricts that by default even for a process the container leaves unconfined.
#
# The AppArmor profiles of passt and pasta that the runner loads are matched by the path of the
# program, and that path is read inside the container too: a distribution that installs pasta as
# a link to passt would run it under a profile written for another layout. A server that has the
# distribution installed does not carry the profiles of Ubuntu, so they are unloaded here, after
# saying which were loaded. Measured on 2026-11-23 on ubuntu-24.04, where without this pasta
# could not read its own namespace in several of the distributions.
#
# Usage: prepare-runner.sh        (as the runner user, with sudo)

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
