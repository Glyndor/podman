# The image an Amazon Linux 2023 package is built and proved in. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:5c38fd85b00ce8c094315d9b71f671f880052314a22bd25f1a027821bf61d9d7

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
