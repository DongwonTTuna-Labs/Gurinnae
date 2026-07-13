# 58. Internal Service and Actor Assertions

Status: **FINAL**  
Specification version: **13.0.0**

## Boundary

The browser communicates only with the Review Console BFF. The BFF validates the sealed session and synchronizer CSRF token, then calls the private Identity API with `X-Gurine-Service-Assertion`. Identity API resolves the opaque session, claims one bounded step-up authorization issue slot, and returns a request-bound `X-Gurine-Actor-Assertion` value. Control API accepts only that actor assertion.

Control API must never parse browser cookies, browser CSRF tokens, OIDC authorization codes or step-up cookies.

## Cryptographic contract

The exact compact format, canonical serialization, request binding, key rotation, TTL and replay semantics are machine-readable in `specs/auth/assertion-contract.yaml`. Positive and negative deterministic vectors are in `specs/auth/test-vectors/`.

Both assertion types use safe HMAC-SHA-256 APIs. First-party Rust remains under `#![forbid(unsafe_code)]`; direct FFI is prohibited.

## Retry

Assertions are single-use. If a downstream response is lost, the BFF requests a fresh actor assertion and retries the command with the same `Idempotency-Key`. Replay rejection therefore does not break idempotent command recovery.
