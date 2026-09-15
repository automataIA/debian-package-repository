# Build environment for the .deb artifacts.
#
# The distribution here sets the glibc floor of every binary we publish:
# a Rust binary built on noble gets `libc6 (>= 2.39)` and is then
# uninstallable on Debian 12 and Ubuntu 22.04. Building on bookworm
# (glibc 2.36) produces one artifact that installs on bookworm, trixie,
# noble and Pop!_OS alike.
FROM debian:bookworm@sha256:6ebd97fa83deb272194a2cf015b3d26a4d538e9ad3a7a79d544c8af5b0a01443

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential debhelper dpkg-dev fakeroot rsync git curl \
        ca-certificates pkg-config lintian desktop-file-utils appstream \
        libssl-dev libxkbcommon-dev python3 xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The crates need a newer rustc than bookworm ships (edition 2024), so the
# toolchain comes from rustup, installed system-wide and world-readable:
# the container runs as the calling user, who must not own /opt.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain 1.93.0 --no-modify-path \
    && chmod -R a+rX /opt/rustup /opt/cargo
ENV PATH=/opt/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
