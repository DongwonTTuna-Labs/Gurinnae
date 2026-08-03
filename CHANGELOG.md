# Changelog

## 13.0.0 — 2026-07-12 — Submission BFF, Scoped Session and Atomic Intake Closure

- Removed every raw response, draft, receipt, verification and management token from Submission API paths and queries.
- Added request-bound service assertions for public-web and response-portal plus opaque scoped Submission sessions.
- Added encrypted host-only BFF cookie and synchronizer-CSRF contracts for response, correction, subscription and receipt scopes.
- Closed response magic-link/OTP promotion, correction draft-upload-preview-submit, subscription verify/manage and receipt exchange flows.
- Added PostgreSQL session, draft attachment and atomic terminalization procedures.
- Added security-scheme/session-flow validators and 15 executable Submission boundary scenarios.

## 13.0.0 — 2026-07-12 — Request-bound Authentication, Cryptography, Parser and Reproducible Verification Closure

- Split session resolution from exact downstream Actor Assertion issuance.
- Bound high-impact authorization to canonical action context, Idempotency-Key and exact Control request bytes.
- Added bounded five-minute retry authorization with at most three fresh Actor Assertion JTIs and terminal close.
- Removed the legacy single-use step-up proof table and function.
- Added exact ChaCha20-Poly1305 envelopes and deterministic vectors for session, step-up transaction, step-up authorization and field encryption.
- Added exact PDF/OCR, CSV, XML, XLSX, DOCX and HWPX parser selection, sandbox limits, dependency versions and malicious fixtures.
- Made PostgreSQL runtime verification write only to temporary paths and assert authority-tree byte stability.
- Added catalog-aware runtime checks for 61 optimistic-concurrency contracts and the final authentication grant lifecycle.
- Preserved 94 screens, 203 external operations, 9 private identity operations, Rustful/Svelteful rules, 300 detection cases and 50 agent cases.

## 8.0.0 — 2026-07-11 — Semantic Closure and One-Shot Authority

- Unified 203 operation contracts, 97 command semantics, persistence, audit and 0..N event cardinality.
- Rebuilt OpenAPI, state, connector, agent, detection and generated-client authority contracts.
- Closed fresh-verifier installation, OIDC service split, Compose configuration forwarding and typed optimistic-concurrency metadata.

## 6.0.0 — 2026-07-11 — Integrated Codex Authority Pack

- Initial integrated authority package. Superseded by 13.0.0.
