# ADR-004: Rust-first production runtime

- Status: Accepted
- Date: 2026-07-10

## Decision

API, ingestion, normalization, identity resolution, deterministic detection, job execution, scheduling, publication projection을 Rust로 구현한다. Python은 package tooling 외 production runtime에서 금지한다.

## Rationale

- one domain/type system
- policy/state transition reuse
- transaction/job/fencing consistency
- fewer generated cross-language domain contracts
- Codex implementation ambiguity reduction

## Exception process

Python-only ML/OCR capability가 필요하면 별도 ADR에서:

- immutable input/output schema
- no direct DB write
- no command/publication authority
- network/secret allowlist
- container isolation
- timeout/resource/cost
- failure fallback

을 정의해야 한다.
