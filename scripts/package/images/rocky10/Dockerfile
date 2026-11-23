# Rocky Linux 10, which the EL 10 package is also proved on. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM quay.io/rockylinux/rockylinux:10@sha256:d24beedc58f79b9e0e9289fedaa4fcbcbe692b1438883a86f177fd7c51053ca8

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
