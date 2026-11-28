# The image an openSUSE Leap 16.1 package is built and proved in. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM docker.io/opensuse/leap:16.1@sha256:2a2850caec07236eccfe98846f5ed18a67739545620bc5364af1999b4b970665

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow, getcap from libcap-progs. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN zypper --non-interactive install --no-recommends util-linux shadow libcap-progs gawk curl && zypper clean --all
