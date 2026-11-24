# The image a Fedora 44 package is built and first tested in. Pinned by digest, which is the
# index of the image, so the arm64 runner pulls its own. Dependabot moves it.
FROM quay.io/fedora/fedora:44@sha256:0daf6a73fb6ad75dcd62d9a5270e58572f1aea95bb9331db7c2eedd6e47c9cb5

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
