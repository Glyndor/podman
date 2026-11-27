# The image an Amazon Linux 2023 package is built and proved in. Pinned by the tag 2023, which floats, and by the digest of the
# index, so the arm64 runner pulls its own. The tag is NOT a dated one (2023.9.20251208.0 and the like): Dependabot once moved
# it to 2023.0.20230614.0, an image of three years before, which it reads as a newer version of "2023". The digest of the tag
# is what Dependabot moves, and .github/dependabot.yml ignores the versions above it.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:47a249649c57ca32b2d4bd5f46149383d5852610eb2c6230e33ce9c3ab8c8459

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
