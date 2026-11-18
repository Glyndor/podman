# `base` is what a Debian 13 customer runs and what the smoke test installs
# into; `build` adds the compiler and the headers. The package is built once on
# Debian 13 and has to install on the other releases too, so the two Ubuntu
# stages are clean installs the same smoke test runs against. They are pinned by
# digest like the rest, so Dependabot moves them.
FROM debian:13@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS base
ENV DEBIAN_FRONTEND=noninteractive

FROM ubuntu:24.04@sha256:a853f94d226358a79c740cfc7bce0c289748f3fe3488d921d038ccd752c61b60 AS ubuntu2404
ENV DEBIAN_FRONTEND=noninteractive

FROM ubuntu:26.04@sha256:513c074113a871b51a8d16ab445c88779d6452d937a164fb5cc479f32668a41d AS ubuntu2604
ENV DEBIAN_FRONTEND=noninteractive

# An older release, only used to prove the package is refused there.
FROM ubuntu:22.04@sha256:9abcaffc92a5279fff3a6a41635c0800ea33e528425fb389658806476e7defde AS ubuntu2204
ENV DEBIAN_FRONTEND=noninteractive

# No gpgme, assuan, subid or sqlite headers on purpose: those libraries change
# name between releases (libgpgme11t64 / libgpgme45, libsubid4 / libsubid5), and
# a package linked against one fails to start on the others. Without the headers
# the build cannot pick them up by accident.
FROM base AS build
# netavark and aardvark-dns need a newer Rust than Debian 13 ships, so cargo and
# rustc come from trixie-backports, which is Debian's own signed archive.
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
	&& apt-get update -qq \
	&& apt-get install -y -qq --no-install-recommends -t trixie-backports cargo rustc \
	&& apt-get install -y -qq --no-install-recommends \
		ca-certificates git make gcc golang-go go-md2man pkg-config dpkg-dev xz-utils \
		protobuf-compiler python3 \
		libseccomp-dev libsystemd-dev libapparmor-dev libbtrfs-dev \
	&& rm -rf /var/lib/apt/lists/*
# The short-name list the package ships is Debian's own, taken from its signed archive:
# upstream's spec fetches the head of a branch that carries no signature.
RUN apt-get update -qq && cd "$(mktemp -d)" \
	&& apt-get download golang-github-containers-common \
	&& dpkg-deb -x golang-github-containers-common_*.deb x \
	&& install -D -m 0644 x/etc/containers/registries.conf.d/shortnames.conf /usr/share/glyndor-build/shortnames.conf \
	&& rm -rf /var/lib/apt/lists/*
