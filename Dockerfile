# The arena server, the directory and the admin surface are one binary; which
# one it is depends on its first argument. So there is one image, and a
# deployment is that image run three times with different commands.
#
# Two stages, because the build needs a Rust toolchain and a C compiler and the
# result needs neither. The binary statically links the simulation core, so the
# runtime layer holds a binary, a certificate store, and the catalog.

FROM rust:1-slim-bookworm AS build
# The core is C99 compiled by build.rs, so a C compiler is not optional here.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# Both trees, and in this shape: server/build.rs reaches ../sim, so the build
# context has to be the repository root rather than server/.
#
# The dependencies are compiled from the manifests alone, against a stub main,
# before any of our own source arrives. Two hundred crates take about five
# minutes on one core and depend on nothing but Cargo.toml and Cargo.lock, so
# building them in the same layer as the source meant every one-line fix
# recompiled all of them: measured, a fifty-second deploy became ten minutes,
# which is a tax on exactly the small fixes that should be cheapest to ship.
#
# The stub layer needs neither tree: cargo detects a build script by the file
# existing, and server/build.rs is not copied yet, so nothing reaches for ../sim
# and `cc` is not built either. Both arrive together afterwards, which is what
# makes a change to the simulation core as cheap to deploy as a change to the
# server.
COPY server/Cargo.toml server/Cargo.lock ./server/
RUN mkdir -p server/src && echo 'fn main() {}' > server/src/main.rs \
 && cargo build --release --manifest-path server/Cargo.toml \
 && rm -rf server/src
COPY sim ./sim
COPY server ./server
RUN cargo build --release --manifest-path server/Cargo.toml

FROM debian:bookworm-slim
# The directory dials a wss arena to verify its address. tokio-tungstenite is
# built with webpki-roots so the roots are compiled in, but anything else that
# ever makes an outbound TLS connection from this image will want the system
# store, and a missing root reads as an inscrutable handshake failure.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/server/target/release/vectorwake-server /usr/local/bin/
# Baked in rather than mounted. The catalog is a versioned artifact with one
# author, so a catalog change is a new image and a restart, which is what
# "authorship, not runtime" means in practice. See docs/architecture/catalog.md.
COPY catalog /catalog
# Where an arena keeps its instance id and its ratings. A volume goes here, so
# a restart is the same instance rather than a new one.
WORKDIR /var/lib/vectorwake
ENTRYPOINT ["vectorwake-server"]
