#!/usr/bin/env bash
#
# Lets an unprivileged user inside a privileged container create a user namespace.
# Ubuntu 24.04 restricts that by default, even for a process the container leaves
# unconfined, and without this the rootless checks would measure the runner and not the
# distribution.

set -euo pipefail

sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
sudo sysctl -w kernel.unprivileged_userns_clone=1 2> /dev/null || true
