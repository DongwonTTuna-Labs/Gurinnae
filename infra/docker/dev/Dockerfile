# syntax=docker/dockerfile:1.12
FROM oven/bun:1.3.14-debian@sha256:9dba1a1b43ce28c9d7931bfc4eb00feb63b0114720a0277a8f939ae4dfc9db6f AS bun

FROM rust:1.97.0-bookworm@sha256:7d0723df719e7f213b69dc7c8c595985c3f4b060cfbee4f7bc0e347a86fe3b6a
ARG CARGO_NEXTEST_VERSION=0.9.140
ARG CARGO_WATCH_VERSION=8.5.3
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates git postgresql-client \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=cache,id=gurine-dev-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=gurine-dev-cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=gurine-dev-cargo-target,target=/tmp/cargo-target \
    CARGO_TARGET_DIR=/tmp/cargo-target \
    cargo install cargo-nextest --version "${CARGO_NEXTEST_VERSION}" --locked \
    && cargo install cargo-watch --version "${CARGO_WATCH_VERSION}" --locked \
    && cargo install sqlx-cli --version 0.9.0 --locked --no-default-features --features rustls,postgres \
    && cargo nextest --version | grep --fixed-strings "cargo-nextest ${CARGO_NEXTEST_VERSION}" \
    && cargo watch --version | grep --fixed-strings "cargo-watch ${CARGO_WATCH_VERSION}" \
    && sqlx --version | grep --fixed-strings 'sqlx-cli 0.9.0'
WORKDIR /workspace
