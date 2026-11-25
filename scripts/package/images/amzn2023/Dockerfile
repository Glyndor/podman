# The image an Amazon Linux 2023 package is built and proved in. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023.0.20230614.0@sha256:d95d75016e4b1f41c71d908862a10c3f026d6eb3df2b2c28cbc8ad38c801de07

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
