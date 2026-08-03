# 57. v10 PostgreSQL Runtime·Identity Assertion·Concurrency 폐쇄 기록

현재 권위 문서: `docs/61-v12-assurance-legal-audit-parser-closure.md`
상태: **HISTORICAL / SUPERSEDED BY v12**

이 문서는 v10에서 PostgreSQL runtime, assertion replay와 optimistic concurrency를 처음 폐쇄한 이력을 보존한다. 활성 권위 계약은 다음이다.

- `docs/60-v11-final-auth-crypto-parser-verification-closure.md`
- `specs/auth/assertion-contract.yaml`
- `specs/config/oidc-contract.yaml`
- `specs/cryptography/`
- `specs/database/migrations/0020_v11_auth_retry_and_verification_closure.sql`
- `specs/database/migrations/0021_v11_remove_legacy_step_up_proof.sql`
- `verification/postgres-runtime-baseline.json`

현재 authority verifier는 21개 migration, 104개 active table, 40개 active first-party function, 61개 concurrency contract와 bounded step-up authorization을 검증한다. Runtime 결과는 tracked authority tree에 기록하지 않고 임시 외부 경로에서 stable baseline과 비교한다.
