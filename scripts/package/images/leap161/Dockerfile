# The image an openSUSE Leap 16.1 package is built and proved in. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM registry.opensuse.org/opensuse/leap:16.1@sha256:755746c7eec92fbdd3c4b02be194bfded4a8d4fde0abedf1835f945d403f43c8

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow, getcap from libcap-progs. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN zypper --non-interactive install --no-recommends util-linux shadow libcap-progs gawk curl && zypper clean --all
