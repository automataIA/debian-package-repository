# Build environment for the .deb artifacts.
#
# The distribution here sets the glibc floor of every binary we publish:
# a Rust binary built on noble gets `libc6 (>= 2.39)` and is then
# uninstallable on Debian 12 and Ubuntu 22.04. Building on bookworm
# (glibc 2.36) produces one artifact that installs on bookworm, trixie,
# noble and Pop!_OS alike.
# Official Rust image, pinned to the immutable multi-platform digest. The slim
# variant is based on Debian Bookworm and avoids downloading and executing the
# rustup installer during this build.
FROM rust:1.93.0-slim-bookworm@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential debhelper dpkg-dev fakeroot rsync git curl \
        ca-certificates pkg-config lintian desktop-file-utils appstream \
        libssl-dev libxkbcommon-dev python3 xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The image supplies Rust 1.93.0 system-wide. build-in-docker overrides
# CARGO_HOME with a writable, repository-local cache for the unprivileged
# calling user while rustup continues to use the read-only system toolchain.
