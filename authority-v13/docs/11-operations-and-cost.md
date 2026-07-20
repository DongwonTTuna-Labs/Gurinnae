# 11. 운영, SLO, 비용 모델

## 1. 운영 철학

구린네는 source·모델·parser가 자주 실패할 것을 전제로 한다. 실패를 숨기거나 자동으로 안전 게이트를 낮추지 않고, **fail-closed but recoverable**하게 설계한다.

## 2. Service Level Objectives — pilot

### Public read

- availability: 99.5% monthly
- cached API P95 < 400 ms
- uncached search P95 < 1.5 s
- correction publication propagation P95 < 10 min

### Control plane

- availability: 99.0% monthly
- command P95 < 1 s excluding uploads/model jobs
- audit event completeness 100%

### Ingestion

- near-real-time source P95 lag < 2 h
- daily source P95 lag < 24 h
- parser success > 99% for unchanged known schema
- unacknowledged schema drift 0

### Publication quality

- provenance coverage 100%
- policy gate bypass 0
- material correction acknowledgement within 1 business day

SLO miss는 자동으로 공개 결과가 잘못됐다는 뜻은 아니지만 source freshness를 public UI에 반영한다.

## 3. Capacity planning envelope

Pilot:

- 1–4 source families
- 1 million raw logical records/month
- 5 TB raw/evidence within first year upper planning envelope
- 20 million normalized records
- 100k signals/month
- 1k active cases
- 100 publications/month
- 20 internal users
- public peak 100 requests/sec with CDN

Scale trigger는 실제 metric 기반으로 ADR을 연다.

## 4. Cost categories

```text
C_total = C_compute + C_database + C_object_storage + C_egress
        + C_model + C_search + C_monitoring + C_security
        + C_legal_editorial + C_support
```

### Compute

API, workers, parser sandbox, frontend build. Autoscaling은 queue age와 request load 기반, source quota를 넘지 않음.

### Database

managed Postgres instance, storage, PITR, replicas. 가장 비싼 query를 먼저 최적화하고 premature sharding 금지.

### Object storage

raw bytes, public assets, backups. lifecycle tiering은 retention/restore requirement와 맞춤.

### Model

input/output/cached token, tool/search, retries. Model별 가격은 변경되므로 config catalog에서 effective date와 currency를 기록한다.

### Human/legal

제품의 필수 원가다. AI 비용만 계산해 사업성을 판단하지 않는다.

## 5. 초기 예산 guardrail

금액은 운영자가 변경할 수 있는 policy이며 가격 견적이 아니다.

```yaml
development:
  llm_daily_hard_cap_krw: 20000
  external_fetch_daily_cap: source_quota
staging:
  llm_daily_hard_cap_krw: 50000
  llm_monthly_hard_cap_krw: 1000000
production_pilot:
  llm_daily_hard_cap_krw: 150000
  llm_monthly_hard_cap_krw: 3000000
  automatic_case_budget_krw: 10000
  high_tier_model_requires_human_approval_above_krw: 5000
```

- budget reservation은 job 시작 전
- 실제 비용 settle
- cap 도달 시 `PAUSED_POLICY`, human queue
- override는 reason, amount, expiry, approver
- provider 자체 hard limit도 설정

## 6. 비용 절감 우선순위

1. rule/SQL로 가능한 작업은 model 금지
2. top signal만 agent investigation
3. document dedupe와 excerpt retrieval
4. structured compact inputs
5. low-cost model first, eval 기반 escalation
6. failed invalid output retry 제한
7. cached stable source parsing
8. batch embedding/model calls only if privacy safe
9. public traffic CDN/cache
10. cold raw storage tiering

“싼 모델”보다 accepted useful suggestion당 비용을 본다.

## 7. Job retry 정책

Failure categories:

```text
TRANSIENT_NETWORK
RATE_LIMITED
SOURCE_OUTAGE
AUTH_FAILURE
SCHEMA_DRIFT
MALFORMED_CONTENT
POLICY_BLOCKED
BUDGET_BLOCKED
MODEL_INVALID_OUTPUT
PERMANENT_NOT_FOUND
INTERNAL_BUG
```

Default:

- transient: exponential backoff + jitter, max attempts
- rate: provider retry-after + quota
- auth: pause source and alert, no blind retry storm
- drift: quarantine and pause checkpoint
- malformed one record: quarantine record, batch policy decides
- policy/budget: no automatic retry until condition changes
- internal bug: limited retry then dead letter

## 8. Source operations

Per source dashboard:

- last successful fetch and source published timestamp
- lag distribution
- request/error/quota
- records/raw bytes
- new/updated/duplicate
- parser success/warnings
- schema fingerprints
- reconciliation count/amount
- checkpoint
- active incident/terms review

Runbooks:

- source outage
- API key expired
- quota exhausted
- schema drift
- upstream correction/deletion
- historical backfill
- erroneous parser rollout

## 9. Data quality operations

Daily:

- required field missing rate
- unknown enum/unit/category
- duplicate natural keys
- amount/quantity outliers
- entity candidate backlog
- source cross-reconciliation

Weekly:

- rule yield and dismissal reasons
- cohort sizes
- source coverage by agency/category
- identity merge review
- correction root causes

## 10. Model operations

Metrics:

- calls/tokens/cost/latency/errors
- JSON validity
- evidence reference validity
- human accept/partial/reject
- prompt injection flags
- task-specific eval score
- abstention

Alert:

- fabricated refs > 0 accepted (critical)
- invalid output rate spike
- cost anomaly
- model alias/version change
- provider retention/terms change

## 11. Editorial operations

Queues:

- untriaged signals age
- investigations overdue
- response deadlines
- review waiting
- legal review waiting
- correction reports
- publication dry-run failures

Workload limit:

새 signal이 human capacity를 넘으면 낮은 priority를 backlog/shadow로 두며 자동 공개로 보상하지 않는다.

## 12. On-call

### Engineering on-call

source, infrastructure, security, data integrity.

### Editorial duty

wrong publication, response/correction, legal inquiry.

### Security/legal escalation

PII leak, account compromise, injunction/law enforcement, whistleblower risk.

연락 체계는 private runbook에 두고 public status에는 필요한 정보만.

## 13. Backup and restore

- PostgreSQL PITR: continuous/WAL managed
- daily logical/physical backup validation
- raw object storage versioning/replication as approved
- audit/publication revision additional immutable export
- key management backup/rotation
- quarterly restore drill

Restore acceptance:

- case/version/approval consistency
- current publication pointer
- audit/outbox gap detection
- object checksum verification
- public projection rebuild
- jobs stale lease reset without duplicate side effects

## 14. Retention summary

ADR-003가 우선.

- public publication revisions/corrections: indefinite
- raw source supporting publication: 7 years minimum after last material use, legal/privacy exception
- nonselected raw: hot 90 days, lower tier up to 3 years based source/replay value
- private response contact/token: purpose-limited, token short, contact 1 year after close unless legal hold
- model raw payload: 90 days default, structured result longer
- operational logs: 30–90 days; security audit 1–7 years by category

## 15. Change management

- source/parser/rule/model/policy 모두 versioned
- staging replay/backtest
- canary or shadow
- rollback threshold
- changelog
- publication-affecting change는 affected-case revalidation

## 16. Launch checklist

- source terms and legal review current
- data map/DPIA
- threat model and pen test
- backup restore drill
- publication/correction tabletop
- response channel tested
- budget/kill switch tested
- public methodology/funding/privacy/terms pages
- on-call ownership
- no real unpublished data in CI/staging screenshots

## 17. Revenue-cost unit economics

분석 단위:

- cost per raw record
- cost per normalized line item
- cost per signal
- cost per triaged signal
- cost per investigated case
- cost per publication
- human hours per material correction
- API customer support cost

수익모델은 public publication 수를 늘려야만 성립하도록 만들지 않는다. API/workspace 매출은 데이터 품질 인프라를 보조해야 한다.

## 18. Graceful degradation

- model outage: deterministic ingestion/detection 계속, investigation suggestions pause
- search outage: direct case routes/API filters 제공
- source outage: last data와 stale banner, 다른 source 계속
- control outage: public read 계속; publication/correction emergency path 별도 검토
- public edge outage: status page and static correction notice option
- DB primary issue: read replica/static cache 가능, writes pause

## 19. Operational anti-patterns

- source error를 empty success로 처리
- retry 무한 루프
- dead letter를 방치
- model output raw를 public에 바로 렌더
- production DB 직접 수정
- 비용 cap을 환경변수 하나로만 두고 audit 없음
- backup 존재만 확인하고 restore 안 함
- correction을 deploy rollback으로 처리

## v2 runtime 운영 단위

비용과 용량을 다음 process/자원 단위로 계측한다.

- Actix public/control/submission request by operationId
- PostgreSQL pool/query/storage/WAL/backup
- Rust worker job type/runtime/attempt
- source egress/raw object bytes
- outbox lag/public projection
- Bun SSR request/build/image memory
- model/OCR calls when enabled

PostgreSQL durable queue의 backlog가 커져도 worker concurrency를 DB connection limit보다 높게 자동 확장하지 않는다. Public API와 SSR은 data pipeline outage 중에도 last-known curated revision을 freshness 표시와 함께 제공할 수 있어야 한다.

Dev/CI 비용은 DB-only와 full-container mode를 분리해 관리한다. Production image와 dependency update는 재빌드·smoke 비용을 포함한다. Cost cap은 publication/evidence gate를 우회하거나 검증이 약한 모델로 자동 fallback하는 근거가 될 수 없다.
