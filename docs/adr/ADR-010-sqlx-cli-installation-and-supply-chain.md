# ADR-010 — SQLx CLI 0.9.0 installation and supply-chain evidence

- Status: Accepted
- Date: 2026-07-10
- Decision owners: platform, security

## Context

Gurine pins SQLx and SQLx CLI to 0.9.0. The dev image originally attempted `cargo install --locked`. SQLx 0.9.0 does not ship the upstream workspace `Cargo.lock`, so that command is not a valid reproducible-install mechanism. Pretending otherwise makes the image contract unbuildable.

## Decision

Install SQLx CLI with:

```text
cargo install sqlx-cli --version 0.9.0 \
  --no-default-features --features postgres,rustls
```

The Dockerfile must contain `SQLX_UPSTREAM_LOCK_ABSENT`. No other tool may inherit this exception automatically.

Before a tool image is approved, capture the resolved dependency graph, full install log, SBOM, vulnerability scan, two clean-build comparisons, and immutable image digest. A dependency graph difference between clean builds is a blocking review item.

## Consequences

The exact top-level CLI version remains fixed, but its transitive resolution is not supplied by upstream as a lockfile. Reproducibility therefore moves to the immutable tool-image digest and recorded build evidence. This is weaker than an upstream lockfile but stronger than a floating or undocumented install.

## Rejected alternatives

- Use `--locked` and accept build failure: rejected as non-operational.
- Copy an invented SQLx lockfile into the package: rejected as fabricated provenance.
- Use an unpinned git checkout: rejected as a supply-chain regression.
- Change SQLx version without compatibility work: rejected because the selected architecture is locked.

## Verification

Static validation rejects `--locked` on the SQLx CLI line, requires the exception marker, and checks exact version/features. Final acceptance requires the build evidence and a non-`PENDING` immutable image digest.


## SQLx 0.9 runtime/TLS feature split

SQLx 0.9 removed deprecated combined runtime-and-TLS features. The application manifest therefore enables `runtime-tokio` and `tls-rustls-ring-webpki` separately. `runtime-tokio-rustls` is forbidden because it is not a valid SQLx 0.9 feature. The SQLx CLI uses its own `rustls` feature, which maps to SQLx's rustls TLS support.
