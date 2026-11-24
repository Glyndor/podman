# The image a Fedora 45 package is built and first tested in. Pinned by digest, which is the
# index of the image, so the arm64 runner pulls its own. Dependabot moves it.
FROM quay.io/fedora/fedora:45@sha256:db14be5698ea04f1f9a4f4fb31945205a696a01f1466cf4a7e5f5a77ca3c7a82

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
