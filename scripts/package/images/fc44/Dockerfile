# The image a Fedora 44 package is built and first tested in. Pinned by digest, which is the
# index of the image, so the arm64 runner pulls its own. Dependabot moves it.
FROM quay.io/fedora/fedora:44@sha256:e47bc35e0f02d8b490f17c9a11dee69c87a393de8d4e5bc81a3fa04b7a7c7ab9

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
