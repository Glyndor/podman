# The image an openSUSE Tumbleweed package is built and proved in. Tumbleweed is rolling, so the tag is latest and the digest is what fixes it. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM registry.opensuse.org/opensuse/tumbleweed:latest@sha256:815edf2ba0730167a9e87199cfe36c07ef391915131b2e44d116a84290a07c87

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow, getcap from libcap-progs. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN zypper --non-interactive install --no-recommends util-linux shadow libcap-progs gawk curl && zypper clean --all
