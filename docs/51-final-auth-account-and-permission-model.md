# 51. 최종 계정·인증·권한 모델

- 공개 열람: 계정 없음
- 구독: email verification
- 정정/contact: email receipt와 anti-abuse
- 소명: request-scoped opaque token + email OTP
- 내부: OIDC Authorization Code + PKCE
- `assurance_level: STEP_UP` action: recent bounded step-up authentication; destructive confirmation alone does not imply Step-up
- server-side capability enforcement
- separation of duties for author/reviewer/publisher
- session revocation and access review
- audit for role changes


## v12 assurance, legal hold, audit export and real parser closure

- Review Console BFF owns browser cookies and synchronizer CSRF.
- Identity API accepts only request-bound service assertions and issues request-bound actor assertions.
- Control API accepts only `X-Gurine-Actor-Assertion`; it never receives browser session or CSRF credentials.
- Assertion format and replay rules are authoritative in `specs/auth/assertion-contract.yaml`.
- Schema mapping concurrency is guarded by `ops.schema_drifts.version`; exact mapping proposals use `(schema_drift_id, mapping_version, mapping_digest)`.
- Queue and source concurrency use `queue_name` and `source_id`, respectively.
