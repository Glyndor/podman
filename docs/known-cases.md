# Known cases

Two things that differ from the distribution's Podman and can surprise someone who moves to this package.

## What the package changes in passt's AppArmor profile

The package installs the AppArmor profiles of passt as upstream ships them, with one rule added to the profile of `pasta`: `signal (receive) set=(term) peer=podman,`. When the last container of a rootless bridge network stops, Podman signals the `pasta` of the rootless network namespace. On Ubuntu 24.04 and 26.04, `/usr/bin/podman` runs under a profile called `podman`, and the signal rules of passt's profile only admit an unconfined sender, so the kernel refuses it (`apparmor="DENIED" operation="signal" profile="pasta" comm="podman" signal=term peer="podman"`) and the API answers `500 rootless netns: kill network process: permission denied` to `POST /containers/<id>/stop`. `podman stop` on the command line fails the same way, with status 125. The rule admits SIGTERM, the only signal Podman 6.2 sends to that pasta, from that one peer and nothing else. The build stops if passt's profile no longer has the shape the rule is added to, or already carries such a rule, and it compiles the result with `apparmor_parser -Q`. passt's own profile and the one in Ubuntu 26.04's `passt` package have the same gap.

## A firewall driver netavark 2 does not have

The package ships netavark 2, which filters with nftables and has no iptables driver. A `containers.conf` that names one, such as `firewall_driver = "iptables"` under `[network]`, stops every container on a bridge network with `netavark: Must provide a valid firewall backend, got iptables`. Remove the line or name `nftables`. GitHub's `ubuntu-26.04` runner image carries such a line in `/etc/containers/containers.conf.d/99-fix-firewall.conf`; a job there can point `CONTAINERS_CONF_OVERRIDE` at a file that names `nftables`, as the build of this repository does.
