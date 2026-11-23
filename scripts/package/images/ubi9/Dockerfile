# Red Hat's UBI 9 image, the repositories of RHEL 9 that need no subscription, which the EL 9 package is also proved on. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM registry.access.redhat.com/ubi9/ubi:latest@sha256:6636b79fba9e5044360366f189333c30b5ce528efd92c40c68b074592b971fcd

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
