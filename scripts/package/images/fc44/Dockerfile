# The image a Fedora 44 package is built and first tested in. Pinned by tag, NOT by digest, on purpose: this is an
# exception to "base images are pinned by digest". quay.io re-points fedora:44 to a new index every day (between 05:56
# and 07:03 UTC) and deletes the previous one at that instant (measured on 2026-11-24: the digests of the last 14 days
# of the tag had all expired), so a pin by digest makes the build fail the next day. What is installed in the image
# comes from the signed repositories of Fedora, which move as well. A registry that kept the digests would change this.
# The tag is the version and not latest, so the image is always Fedora 44. See docs/packages.md.
FROM quay.io/fedora/fedora:44

# What the proof of a package runs on this machine, named in scripts/package/verify/test-tools.txt: runuser
# comes from util-linux, useradd, newuidmap and newgidmap from shadow-utils, getcap from libcap. A minimal image
# of the distribution lacks some of them, and the proof refuses to start without them.
RUN dnf install -y --setopt=install_weak_deps=False util-linux shadow-utils libcap gawk && dnf clean all
