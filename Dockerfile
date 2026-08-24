# The arena, directory, bot supervisor, and meta-layer are one binary. Its
# first argument selects the role, so one image supplies every Rust service in
# the deployment. The meta-layer also serves the admin API.
#
# Two stages, because the build needs a Rust toolchain and a C compiler and the
# result needs neither. The binary statically links the simulation core, so the
# runtime layer holds a binary, a certificate store, and the catalog.

# Calibration binds the Rust and C toolchains to the executable it measures.
# The immutable full image already contains build-essential, so the release
# rebuild cannot silently pick up a newer compiler from a floating apt index.
FROM rust:1.89.0-bookworm@sha256:948f9b08a66e7fe01b03a98ef1c7568292e07ec2e4fe90d88c07bb14563c84ff AS build
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
# Calibration fingerprints the shipped catalog fixture and this build recipe.
# Both must exist at their repository-relative paths during the real build.
COPY catalog ./catalog
COPY Dockerfile ./Dockerfile
# And the reference zone, because the binary compiles part of it in: main.rs
# takes the Ladder seed, attempt registry, and signed calibration attestation
# with include_str!, so a context without this directory does not build a
# server with no ladder, it fails to compile. Which is how it broke.
# The file landed, every test passed on a full checkout, and this build stopped
# dead at `couldn't read src/../../zone/ladder.json` for four pushes running,
# each of them green on the test job above it.
COPY zone ./zone
# Which commit this is, baked into the binary so every process can say so.
#
# Deliberately here rather than in the environment of a running container.
# Compose recreates a container whose configuration moved, so a commit passed
# in at run time would restart every service on every push, Caddy included,
# and Caddy restarting is how this game once spent three of its five weekly
# certificate issuances. An image only replaces the containers whose image
# changed, which is exactly the set that has new code in it.
#
# And after the dependency layer, so stamping a commit does not invalidate the
# five minutes of crates above it.
ARG VW_COMMIT=unknown
ENV VW_COMMIT=$VW_COMMIT
RUN cargo build --release --manifest-path server/Cargo.toml

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
# The directory dials a wss arena to verify its address. tokio-tungstenite is
# built with webpki-roots so the roots are compiled in, but anything else that
# ever makes an outbound TLS connection from this image will want the system
# store. Copy the builder's bundle instead of resolving packages from a live
# apt index, which keeps the measured runtime libraries and final image fixed.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /src/server/target/release/vectorwake-server /usr/local/bin/
# Baked in rather than mounted. The catalog is a versioned artifact with one
# author, so a catalog change is a new image and a restart, which is what
# "authorship, not runtime" means in practice. See docs/architecture/catalog.md.
COPY catalog /catalog
# Where an arena keeps its instance id, and the rated events it has not handed
# off yet. A volume goes here, so a restart is the same instance rather than a
# new one and a debt to the meta-layer survives it.
WORKDIR /var/lib/vectorwake
ENTRYPOINT ["vectorwake-server"]
