# The image the Arch Linux package is built and proved in. Arch is a rolling release, so the
# tag is latest and the digest is what fixes it. Dependabot moves the digest.
FROM docker.io/library/archlinux:latest@sha256:d4594bb2300cba11f41c2f27923eb56f63d9988909c402f9c95517d1e362c899

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN pacman -Syu --noconfirm --needed util-linux shadow libcap gawk curl && pacman -Scc --noconfirm
