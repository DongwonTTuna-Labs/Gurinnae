# CI/CD와 릴리스

## 1. 원칙

CI는 코드가 컴파일되는지만 보는 것이 아니라 공개 정책·DB 권한·생성 계약·container runtime을 함께 검증한다. Untrusted PR code와 secret/deployment 권한을 분리한다.

## 2. PR required checks

### Spec

- package validator
- schema/fixture/provenance
- Markdown links
- architecture baseline

### Rust

- toolchain exact
- `cargo fmt --all -- --check`
- `cargo check --workspace --all-targets --all-features --locked`
- clippy `-D warnings`
- unit/property tests
- dependency/license/advisory

### Database

- PostgreSQL 18.4 service
- clean migration
- role/grant negative tests
- repository/integration tests
- `cargo sqlx prepare --workspace --check`

### Contract

- Rust OpenAPI generation
- OpenAPI validation/policy
- clean generated JSON diff
- Hey API generation
- clean TS client diff
- compatibility report

### Frontend

- Bun exact/frozen install
- Biome
- svelte-check
- unit/component
- production build

### Acceptance/security

- policy/architecture acceptance
- secret scan
- SSRF/parser/prompt injection
- public/private bundle/import scan

### Container

- exact base/tag policy
- image build
- full Compose smoke
- SvelteKit Bun SSR smoke
- graceful shutdown

## 3. CI trust boundary

- fork/untrusted PR에 production secret 없음
- PR head action/workflow를 privileged context에서 실행하지 않음
- deployment job은 protected branch/environment approval
- artifact provenance와 commit SHA 확인
- dependency install scripts/repository hooks 최소화

## 4. Build artifact

- Rust binaries
- SvelteKit build/runtime image
- migration image/job
- OpenAPI JSON
- SBOM
- vulnerability report
- image digest/signature/provenance

## 5. Migration release

1. backup/PITR health
2. migration compatibility static review
3. staging clean + populated migration
4. one-shot production migrator
5. schema version 확인
6. canary service
7. smoke/metrics
8. rollout

Backward-incompatible contract migration은 expand/deploy/backfill/switch/contract 여러 release로 나눈다.

## 6. Deployment order

- public/control/submission API와 worker가 새/이전 schema에 호환되는지 명시
- web은 필요한 API operation이 배포된 뒤 rollout
- generated client와 API revision mapping
- public projection schema migration/rebuild

## 7. Rollback

Code rollback이 DB destructive reverse migration을 요구하지 않도록 설계한다. Rollback plan:

- prior image digest
- feature/connector/rule kill switch
- publication command disable
- public cache purge
- projection rebuild
- migration forward fix

## 8. Environments

- local
- CI ephemeral
- staging synthetic/redacted
- production

Staging에 실제 secret/PII를 복제하지 않는다. Production data debug는 audited least-privilege path만.

## 9. Release gate

Release evidence:

- required checks PASS
- generated drift 0
- migration/SQLx PASS
- acceptance hard gate PASS
- critical/high vulnerability disposition
- image digest/SBOM/signature
- rollback tested/ready
- open incidents/error budget
- legal/editorial gate for actual publication capability

## 10. Scheduled verification

- weekly dependency/advisory
- monthly restore/sample replay
- quarterly disaster/security/editorial drills
- source schema/terms periodic revalidation
- runtime/toolchain update compatibility branch
