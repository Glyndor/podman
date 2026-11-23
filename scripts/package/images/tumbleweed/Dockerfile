# The image an openSUSE Tumbleweed package is built and proved in. Tumbleweed is rolling, so the tag is latest and the digest is what fixes it. Pinned by digest, which is the index of the image, so the arm64 runner pulls its own.
# Dependabot moves the digest within the release.
FROM registry.opensuse.org/opensuse/tumbleweed:latest@sha256:8d75d2997058df2cd0821d07e17a285b4548e77781a88c0dae8d1b17dbca3c1b

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow, getcap from libcap-progs. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN zypper --non-interactive install --no-recommends util-linux shadow libcap-progs gawk curl && zypper clean --all
