# shellcheck shell=bash
#
# What a customer expects to find on disk after a native package of Podman is installed, in two lists the
# proofs of the packages ask for: the engine, which every package ships, and the configuration of the
# containers-common of the release, which the rpm packages ship under /usr/share/containers and the pacman
# package leaves to Arch's own containers-common. Nothing is under /etc/containers: that is the administrator's.
# Sourced by rpm-test.sh and pacman-test.sh, never run. GLYNDOR_ROOT is a root to look under, for the tests.

ENGINE_FILES=(/usr/bin/podman /usr/bin/podman-remote /usr/libexec/podman/quadlet /usr/libexec/podman/rootlessport
	/usr/libexec/podman/netavark /usr/libexec/podman/aardvark-dns
	/usr/lib/systemd/system/podman.socket /usr/lib/systemd/user/podman.socket
	/usr/lib/systemd/system-generators/podman-system-generator /usr/lib/systemd/user-generators/podman-user-generator
	/usr/lib/tmpfiles.d/podman.conf /usr/share/bash-completion/completions/podman
	/usr/share/zsh/site-functions/_podman /usr/share/fish/vendor_completions.d/podman.fish)
CONFIG_FILES=(/usr/share/containers/policy.json /usr/share/containers/seccomp.json /usr/share/containers/containers.conf
	/usr/share/containers/registries.conf /usr/share/containers/registries.conf.d/000-shortnames.conf)

ships_engine() {
	local f
	for f in "${ENGINE_FILES[@]}"; do
		[ -e "${GLYNDOR_ROOT:-}$f" ] || { echo "the package does not ship $f" >&2; return 1; }
	done
}

ships_config() {
	local f
	for f in "${CONFIG_FILES[@]}"; do
		[ -s "${GLYNDOR_ROOT:-}$f" ] || { echo "the package does not ship $f" >&2; return 1; }
	done
}
