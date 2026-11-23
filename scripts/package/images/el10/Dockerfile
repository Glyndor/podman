# The image an EL 10 package is built in, and the AlmaLinux 10 it is first proved on. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM quay.io/almalinuxorg/almalinux:10@sha256:498b0b31dab82c3be22ac50efb8bf865adce85576495da20de8cedc48b29eec6

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
