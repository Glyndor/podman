# `base` is what a Debian 13 customer runs and what the smoke test installs
# into; `build` adds the compiler and the headers. The package is built once on
# Debian 13 and has to install on the other releases too, so the two Ubuntu
# stages are clean installs the same smoke test runs against. They are pinned by
# digest like the rest, so Dependabot moves them.
FROM debian:13@sha256:3cda3ca472ce45507a5109c6a3907093e24d9ae67d55954c9a07a45665dafba2 AS base
ENV DEBIAN_FRONTEND=noninteractive

FROM ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b AS ubuntu2404
ENV DEBIAN_FRONTEND=noninteractive

FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS ubuntu2604
ENV DEBIAN_FRONTEND=noninteractive

# An older release, only used to prove the package is refused there.
FROM ubuntu:22.04@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb AS ubuntu2204
ENV DEBIAN_FRONTEND=noninteractive

# Debian 12, glibc 2.36, for the same proof.
FROM debian:12@sha256:1d04200c2ece1d4d75a2a6f8e11ebce7d86a2ae28b34bb2c9cbb3ee9f4953e75 AS debian12
ENV DEBIAN_FRONTEND=noninteractive

# No gpgme, assuan, subid or sqlite headers on purpose: those libraries change
# name between releases (libgpgme11t64 / libgpgme45, libsubid4 / libsubid5), and
# a package linked against one fails to start on the others. Without the headers
# the build cannot pick them up by accident.
FROM base AS build
# The apparmor package is here for apparmor_parser, which compiles the profile of pasta
# the build edits; its abi and abstractions are the base that profile includes.
# netavark and aardvark-dns need a newer Rust than Debian 13 ships, and Podman asks for a newer
# Go than the 1.24 of trixie (its go.mod names the release), so cargo, rustc and go come from
# trixie-backports, which is Debian's own signed archive. With a Go at least as new as the one
# go.mod asks for, the build uses it and fetches no toolchain from the module proxy.
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
	&& apt-get update -qq \
	&& apt-get install -y -qq --no-install-recommends -t trixie-backports cargo rustc golang-go \
	&& apt-get install -y -qq --no-install-recommends \
		ca-certificates git make gcc go-md2man pkg-config dpkg-dev xz-utils file \
		protobuf-compiler python3 apparmor \
		libseccomp-dev libsystemd-dev libapparmor-dev libbtrfs-dev \
	&& rm -rf /var/lib/apt/lists/*
# The short-name list the package ships is Debian's own, taken from its signed archive:
# upstream's spec fetches the head of a branch that carries no signature.
RUN apt-get update -qq && cd "$(mktemp -d)" \
	&& apt-get download golang-github-containers-common \
	&& dpkg-deb -x golang-github-containers-common_*.deb x \
	&& install -D -m 0644 x/etc/containers/registries.conf.d/shortnames.conf /usr/share/glyndor-build/shortnames.conf \
	&& rm -rf /var/lib/apt/lists/*
# passt: Podman 6.2.0 passes pasta an option (--map-guest-addr) that the passt of Ubuntu
# 24.04 does not have, and upstream's spec asks for 20260716 or newer, which no supported
# release ships. passt's own tags carry no signature, so the source comes from Debian's
# signed archive instead: trixie-backports has a release newer than that floor, and
# apt checks the source package against the signed Release file.
RUN echo "deb-src http://deb.debian.org/debian trixie-backports main" >> /etc/apt/sources.list.d/backports.list \
	&& apt-get update -qq && mkdir -p /usr/share/glyndor-build && cd /usr/share/glyndor-build \
	&& apt-get source -qq -t trixie-backports passt \
	&& ln -s "$(ls -d passt-*/ | head -n 1)" passt \
	&& rm -rf /var/lib/apt/lists/*
