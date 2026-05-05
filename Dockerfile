# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the claurst REST endpoint.
#
# Stage 1 (`builder`) compiles the Rust workspace under `src-rust/` in
# release mode and produces the single `claude` binary that hosts the
# `/ask` endpoint. Stage 2 (`runtime`) is a slim Debian image carrying
# only the binary plus the OS-level dependencies it links against
# (libssl3, ca-certificates) so the published image is small enough to
# pull quickly into Azure Container Apps.
#
# Why two stages:
#   * The Rust toolchain, OpenSSL headers, and cargo's build cache
#     together exceed 1 GB. Shipping any of that into production is
#     unnecessary surface area.
#   * `cargo build --release` artefacts are statically linked against
#     the Rust standard library; the only dynamic deps are libssl3 and
#     libc, which are present in `debian:bookworm-slim` (libc) and
#     installed explicitly (libssl3).
#
# Why native-tls and not rustls:
#   The workspace's `reqwest` dependency is configured with the
#   `native-tls` feature (see `src-rust/Cargo.toml`). On Linux that
#   binds to OpenSSL, which is why both the builder and runtime stages
#   install the OpenSSL development headers (builder) and runtime
#   shared libraries (runtime).
#
# Why the builder stage runs `--bin claude --package claude-code`:
#   The workspace declares ~12 member crates (cc-core, cc-tools,
#   cc-tui, …) but only the `claude-code` package produces a binary.
#   Targeting it explicitly keeps the build from compiling test-only
#   helpers in `dev-dependencies` of every workspace member and shaves
#   ~10–20% off cold-build time without changing the resulting binary.

# ===========================================================================
# Stage 1 — builder
# ===========================================================================
#
# Rust 1.88 is the floor: transitive deps in Cargo.lock require it.
#   * `clap 4.6.0` sets `edition = "2024"` (needs ≥ 1.85)
#   * `darling 0.23` and `instability 0.3.12` set `rust-version = "1.88"`
# Pinning to 1.88 keeps the toolchain reproducible across CI and ACR.
FROM rust:1.88-slim-bookworm AS builder

# OpenSSL development headers are needed to compile the `native-tls`
# crate. `pkg-config` is how `openssl-sys`'s build script locates the
# library. `ca-certificates` is needed so cargo can fetch from
# crates.io over HTTPS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        pkg-config \
        libssl-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build context is the repo root; the Rust workspace lives one level
# deeper under `src-rust/`. Copy only that directory — the spec/, public/,
# test/, and deploy/ trees aren't needed to compile the binary, and
# excluding them via `.dockerignore` keeps the build context small.
WORKDIR /build
COPY src-rust/ ./src-rust/

WORKDIR /build/src-rust

# Build the binary in release mode.
#
#   --release   produces an optimised binary; the runtime image needs
#               this for acceptable agentic-loop latency.
#   --locked    enforces parity with the committed Cargo.lock so the
#               image is reproducible from the same source revision.
#   --bin / --package
#               narrows the build to the single binary we ship.
#
# BuildKit cache mounts (registry, git, target) would normally keep the
# build warm across runs, but ACR Tasks' default builder is the legacy
# (non-BuildKit) Docker engine, which rejects `RUN --mount=...`. So this
# is the BuildKit-free form: cargo state lives inside the layer, the
# build artefact is copied to a path that survives, and BuildKit-aware
# CI can re-introduce cache mounts via a Buildx config without touching
# this file.
RUN cargo build --release --locked --bin claude --package claude-code \
    && cp target/release/claude /usr/local/bin/claude

# ===========================================================================
# Stage 2 — runtime
# ===========================================================================
FROM debian:bookworm-slim AS runtime

# Runtime dependencies:
#   * libssl3        — pairs with the `native-tls` link from the
#                      builder stage; without it the binary fails to
#                      load with "error while loading shared libraries".
#   * ca-certificates — required for outbound HTTPS to DeepSeek's
#                      Anthropic-compatible endpoint and to any URL
#                      reached via the `web_fetch` tool.
#
# A dedicated non-root user runs the binary. Container Apps does not
# require this, but it costs nothing and aligns with defence-in-depth.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libssl3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 claurst \
    && useradd --system --uid 10001 --gid claurst \
        --home-dir /nonexistent --no-create-home \
        --shell /usr/sbin/nologin claurst

# Copy the binary out of the builder stage. Owned by root; the non-root
# runtime user only needs execute permission, which the default 0755
# from `cargo build` already provides.
COPY --from=builder /usr/local/bin/claude /usr/local/bin/claude

# Drop privileges before the entrypoint runs. The /ask endpoint never
# writes to the filesystem (the restricted tool subset is read-only) so
# the unprivileged user has nothing to do but listen on the bound port.
USER claurst:claurst

# Default working directory. The binary's `web_fetch` and `todo` tools
# don't need any specific cwd; this just keeps relative-path output
# (e.g. tracing) tidy.
WORKDIR /app

# Container Apps' public ingress is fronted by a managed reverse proxy
# that terminates TLS on 443 and forwards to a configurable container
# port (default 8080). The binary is expected to bind to 0.0.0.0:8080
# in `serve` mode — see the wiring in `crates/cli/src/serve.rs` and
# `crates/http/src/lib.rs`.
EXPOSE 8080

# Secrets are injected by Container Apps as env vars (see
# `deploy/secrets/setup-secrets.sh`):
#   * CLAURST_API_KEY  — required; the X-API-Key the server will accept.
#   * DEEPSEEK_API_KEY — required; passed through to cc-api as the
#                        upstream model auth.
# We deliberately don't `ENV` defaults for either — the binary refuses
# to start without them, which is the correct fail-loud behaviour.

# Default tracing level. `RUST_LOG=info` keeps per-request lines
# without flooding the container log with debug spans.
ENV RUST_LOG=info

# `claude` is the binary name from `crates/cli/Cargo.toml`'s [[bin]]
# stanza. Keeping the entrypoint a single token lets operators append
# alternative subcommands (`claude --version`, `claude auth status`,
# …) for debugging by overriding only `command:` in the Container Apps
# template, leaving the entrypoint intact.
ENTRYPOINT ["claude"]

# `serve` is the canonical subcommand that brings up the /ask REST
# server (wired into the binary by a sibling sub-AC of AC 6). Container
# Apps will run this CMD by default; operators can override via the
# `args:` field in the revision template if they ever need to start the
# binary in another mode without rebuilding the image.
CMD ["serve"]
