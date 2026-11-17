# Two stages on one pinned Debian 13 base: `base` is what a customer runs and
# what the smoke test installs into; `build` adds the compiler and the headers.
FROM debian:13@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS base
ENV DEBIAN_FRONTEND=noninteractive

FROM base AS build
# netavark and aardvark-dns need a newer Rust than Debian 13 ships, so cargo and
# rustc come from trixie-backports, which is Debian's own signed archive.
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
	&& apt-get update -qq \
	&& apt-get install -y -qq --no-install-recommends -t trixie-backports cargo rustc \
	&& apt-get install -y -qq --no-install-recommends \
		ca-certificates git make gcc golang-go go-md2man pkg-config dpkg-dev xz-utils \
		protobuf-compiler \
		libgpgme-dev libseccomp-dev libsystemd-dev libbtrfs-dev libdevmapper-dev \
		libglib2.0-dev libassuan-dev libgpg-error-dev libsubid-dev libsqlite3-dev \
	&& rm -rf /var/lib/apt/lists/*
