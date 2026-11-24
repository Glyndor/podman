# The image an openSUSE Tumbleweed package is built and proved in. Tumbleweed is rolling, so the tag is latest, and it is
# pinned by tag, NOT by digest, on purpose: this is an exception to "base images are pinned by digest". The registry stops
# serving the digests it replaces after a few days (measured on 2026-11-24: a digest taken a few days earlier was gone),
# so a pin by digest makes the build fail. What is installed in the image comes from the signed repositories of
# openSUSE, which roll as well. A registry that kept the digests would change this. See docs/packages.md.
FROM registry.opensuse.org/opensuse/tumbleweed:latest

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow, getcap from libcap-progs. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN zypper --non-interactive install --no-recommends util-linux shadow libcap-progs gawk curl && zypper clean --all
