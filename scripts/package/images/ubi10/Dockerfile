# Red Hat's UBI 10 image, which the EL 10 package is also proved on. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM registry.access.redhat.com/ubi10/ubi:latest@sha256:87ceab8634a53a36c75a8ba7282f09f11c46ab3e8906db6c6d2b3cd2a7dc4f4e

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
