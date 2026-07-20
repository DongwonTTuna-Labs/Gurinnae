# 시스템 아키텍처 — 최종 Rust/Actix/SQLx/Bun 모노레포

상태: **FINAL / ONE-SHOT IMPLEMENTATION AUTHORITY**  
기준일: **2026-07-11**  
기계 판독 권위: `specs/architecture/**`, `specs/repository/**`, `specs/deployment/**`

## 1. 목표

구린네는 공개 공공데이터를 수집·보존·정규화하고, 결정적 규칙과 제한된 AI 조사 보조를 통해 이상 징후를 조사한 뒤 사람의 독립 검토와 소명권을 거쳐 공개하는 시스템이다. 최종 source tree는 개발용 synthetic mode와 운영용 live connector mode를 모두 포함한다. MVP, fixture-only backend, 단일 worker, 후속 구현 표시는 허용하지 않는다.

## 2. 고정 기술

```text
Rust 1.97.0 / edition 2024
Actix Web 4.14.0
Tokio
SQLx 0.9.0
PostgreSQL 18.4 / postgres:18.4-bookworm
Utoipa 5.5.0 + utoipa-actix-web 0.1.2
OpenAPI 3.1.0 / JSON Schema 2020-12
Bun 1.3.14
Svelte 5.56.4 / SvelteKit 2.69.2
TypeScript 5.9.3 strict
svelte-adapter-bun 1.0.1
Biome 2.5.3 / svelte-check 4.3.1
@hey-api/openapi-ts 0.99.0 / @hey-api/client-fetch 0.13.1
Valibot 1.1.0
Docker Compose
```

Production runtime 언어는 Rust와 TypeScript뿐이다. Python은 authority validator와 reference evaluator 같은 명세 도구에만 허용한다.

## 3. 핵심 원칙

1. **증거 우선**: 공개 claim은 SourceDocument와 locator·hash까지 추적한다.
2. **결정적 코어**: 수집, hash, parsing, normalization, rule, 상태 전이, publication gate는 Rust 코드다.
3. **AI 비권위성**: Agent는 read-only suggestion artifact만 만들며 command·publication 권한이 없다.
4. **배포 경계로 정책 강제**: Public/Control/Submission API와 DB role·OpenAPI·client·network를 분리한다.
5. **PostgreSQL durable truth**: aggregate, version, audit, outbox/inbox, durable job, source checkpoint의 machine truth다.
6. **원샷 완제품**: 내부 작업 순서는 나눌 수 있지만 사용자에게는 전체 기능과 모든 gate가 통과한 source archive만 제출한다.

## 4. 실행 단위

### HTTP·BFF

- `public-api`: 승인된 `public` projection GET만 제공한다.
- `control-api`: 내부 조사·편집·운영 command/query를 제공한다.
- `submission-api`: token/email proof 범위의 소명·정정·구독 intake를 제공한다.
- `public-web`: 익명 공개 SvelteKit SSR.
- `review-console`: OIDC BFF와 내부 조사 SvelteKit SSR.
- `response-portal`: 소명 요청 전용 SvelteKit SSR.

### Background

- `ingest-worker`: official source fetch, checkpoint, raw bytes, source drift.
- `document-extractor`: PDF/XLSX/CSV/XML/DOCX/HWPX 격리 추출.
- `analysis-worker`: normalization, entity resolution, deterministic rule, bounded agent runs.
- `projection-worker`: 승인된 revision을 public projection으로 적용.
- `notification-worker`: 승인된 template과 consent를 통한 메일 delivery.
- `workflow-worker`: attachment scan, intake promotion, export, audit checkpoint, reconciliation.
- `scheduler`: source/rule/reconciliation schedule과 fenced job 생성.
- `migrator`: one-shot SQLx migration.
- `egress-gateway`: source, AI, object-store, SMTP, OIDC의 유일한 외부 egress.

단일 `services/worker`와 단일 `WORKER_DATABASE_URL`은 금지한다.

## 5. Monorepo 경계

최종 물리적 구조는 `specs/repository/final-tree.yaml`이 권위다. 32개 Cargo member와 9개 Bun workspace를 사용한다.

```text
apps/{public-web,review-console,response-portal}
services/{public-api,control-api,submission-api,ingest-worker,analysis-worker,
          projection-worker,notification-worker,workflow-worker,document-extractor,
          scheduler,migrator,egress-gateway,oidc-test-provider}
crates/{domain,application,api-contracts,persistence-postgres,publication-policy,
        ingestion,normalization,identity-resolution,detection,jobs,object-store,
        email,auth,source-connectors,agent-orchestration,observability,test-support,...}
packages/{api-client-public,api-client-control,api-client-submission,ui,config,...}
```

### 의존 방향

```text
domain
  ↑
application + publication-policy
  ↑
ports/adapters: persistence, source, object-store, email, auth, agent
  ↑
service composition roots
```

Domain은 Actix, SQLx, Utoipa, 환경변수, 파일시스템, 네트워크를 알지 않는다. HTTP DTO, SQLx row, domain type은 별개다.

## 6. API 생성 계약

```text
Rust DTO + Actix handler + Utoipa
→ public/control/submission/identity OpenAPI JSON
→ @hey-api/openapi-ts
→ four typed Fetch clients (public, submission, control, internal identity)
→ SvelteKit server-only wrapper
```

- 전체 operation: 212
- Query: 107
- Command: 105
- HTTP non-GET command: 102
- Public/Submission/Control/Identity: 41/34/131/6

Generated artifact는 직접 수정하지 않는다. OpenAPI와 client는 clean regeneration 후 diff가 0이어야 한다.

## 7. 데이터 흐름

### 수집

```text
Source registry/schedule
→ egress gateway allowlist
→ FetchAttempt
→ immutable raw bytes + SHA-256
→ SourceDocument processing/record status
→ sandboxed extraction
→ parsed record + field provenance
→ deterministic normalization
→ entity resolution candidate
→ rule run
→ anomaly signal
```

Live connector는 `specs/connectors/<source>/`의 operation·field mapping·checkpoint·error policy를 따른다. Synthetic fixture는 구조 검증용이며 live 성공 증거가 아니다. Production 활성화는 activation receipt와 official payload fingerprint를 요구한다.

### 조사·공개

```text
Signal
→ Case / Hypothesis / Evidence / Claim
→ ResponseRequest / Response
→ immutable ReviewSnapshot
→ independent ReviewDecision
→ PublicationPreview
→ PublicationRevision
→ outbox integration events
→ public projection
```

승인 대상 hash가 바뀌면 승인은 stale다. 자동 agent와 service account는 human reviewer/publisher가 될 수 없다.

## 8. Command와 event

각 command는 `specs/application/command-semantics.yaml`에서 다음을 가진다.

- aggregate와 target
- auth/capability/step-up
- precondition
- transaction isolation
- exact statement intent와 row cardinality
- version predicate
- repository method
- audit action
- domain event 0..N
- integration event 0..N
- compensation과 receipt

Query는 DB mutation, domain event, integration event를 발생시키지 않는다. Integration event는 transactional outbox와 consumer inbox를 사용한다. Terminal observability event만 consumer가 없을 수 있다.

## 9. DB와 보안

Schema는 `raw`, `core`, `editorial`, `intake`, `ops`, `public`이다. 권한은 `specs/database/privilege-matrix.yaml`과 마지막 privilege closure migration이 권위다.

- Public API는 `public`만 SELECT한다.
- Submission API는 token-scoped SECURITY DEFINER procedure만 사용한다.
- Audit/outbox 직접 mutation은 금지한다.
- Review snapshot/decision/publication revision은 immutable하다.
- SourceDocument와 RuleRun은 전면 immutable이 아니라 허용된 lifecycle transition만 가능하다.
- 모든 runtime login role은 superuser/BYPASSRLS가 아니다.

## 10. SvelteKit SSR

- Public query는 `+page.server.ts`/`+layout.server.ts`에서 public client를 사용한다.
- Internal command는 form action/server endpoint에서 control client를 사용한다.
- Response intake는 response portal server와 submission client를 사용한다.
- Control/Submission client, credential, internal base URL은 browser bundle에 들어가지 않는다.
- Cross-request mutable module state와 `{@html}`은 금지한다.
- External form/env/session payload는 Valibot으로 runtime 검증한다.

## 11. Network

Internal network는 직접 인터넷 route가 없다. 외부 통신은 channel별 egress gateway를 통한다.

```text
ingest-worker       → /source
analysis-worker     → /ai
notification-worker → /smtp
workflow/extractor  → /object-store
review-console      → /oidc
```

Gateway는 DNS/IP 재검증, private/link-local/metadata IP 차단, redirect 재검증, body/timeout 제한과 host allowlist를 적용한다.

## 12. 관측성과 운영

모든 service는 request/job/source/case correlation ID, structured trace, redaction, liveness/readiness를 제공한다. 외부 dependency 장애는 영향 capability만 degraded로 만들며 무관한 public read를 중단하지 않는다.

필수 운영 기능:

- source freshness/schema drift
- queue age/lease/retry/DLQ
- outbox lag/projection mismatch
- provider cost/budget/kill switch
- audit chain/checkpoint verification
- backup/PITR/object restore
- graceful shutdown과 restart recovery

## 13. 완료 기준

완성 source tree는 다음을 모두 증명한다.

- 모든 Cargo/Bun workspace clean build
- PostgreSQL 18.4 migration/privilege/RLS/runtime security test
- SQLx live prepare + offline build
- 다섯 OpenAPI의 공식 validation과 네 client generation/strict compile
- 94개 화면·212개 operation E2E
- 258개 acceptance scenario executable receipt
- 300개 detection oracle + 50개 agent eval
- live connector recorded contract test와 production preflight
- Docker development/test/production topology
- backup/restore, restart, graceful shutdown
- first-party unsafe/panic/placeholder 0


## v12 assurance, legal hold, audit export and real parser closure

- Review Console BFF owns browser cookies and synchronizer CSRF.
- Identity API accepts only request-bound service assertions and issues request-bound actor assertions.
- Control API accepts only `X-Gurine-Actor-Assertion`; it never receives browser session or CSRF credentials.
- Assertion format and replay rules are authoritative in `specs/auth/assertion-contract.yaml`.
- Schema mapping concurrency is guarded by `ops.schema_drifts.version`; exact mapping proposals use `(schema_drift_id, mapping_version, mapping_digest)`.
- Queue and source concurrency use `queue_name` and `source_id`, respectively.
