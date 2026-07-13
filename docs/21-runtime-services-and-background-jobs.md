# Runtime 서비스와 백그라운드 작업

## 1. Process model

```text
public-api      Actix Web
control-api     Actix Web
submission-api  Actix Web
worker          Tokio loop + bounded concurrency
scheduler       Tokio schedule/reconciliation
public-web      Bun/SvelteKit SSR
response-portal Bun/SvelteKit SSR
review-console  Bun/SvelteKit SSR
migrator        one-shot SQLx command
```

한 process가 모두를 실행하는 monolith mode는 test utility 외에는 금지한다.

## 2. Common runtime library

Service 간 공유:

- typed configuration
- tracing/metrics
- build metadata
- health/readiness model
- graceful shutdown
- DB pool factory by role
- clock/ID adapters

Secret/permission이 다른 service config를 하나의 거대한 struct로 공유하지 않는다.

## 3. Graceful shutdown

API:

1. readiness false
2. 새 connection/command drain
3. in-flight bounded wait
4. transaction 종료
5. telemetry flush

Worker:

1. new claim stop
2. active handler cancellation policy
3. heartbeat/lease relinquish 또는 expiry
4. side effect fencing
5. telemetry flush

## 4. Job lifecycle

```text
PENDING → RUNNING → SUCCEEDED
                 ↘ RETRY_WAIT → RUNNING
                 ↘ BLOCKED
                 ↘ DEAD_LETTER
                 ↘ CANCELLED
```

상태 변경은 append-only attempts/evidence를 남긴다. `RUNNING`은 lease가 없으면 유효하지 않다.

## 5. Concurrency

- job type별 concurrency limit
- source/domain별 rate limit
- global DB pool limit
- model/OCR separate budget
- queue priority starvation 방지
- high-cardinality tenant/source unbounded semaphore 금지

## 6. Idempotency patterns

- raw document: source identity + content hash
- parser: document hash + parser version
- normalization: parser output + normalization version
- rule: input set hash + rule version/parameters
- projection: publication revision ID
- outbox delivery: event ID + consumer

## 7. Failure taxonomy

```text
TRANSIENT_NETWORK
RATE_LIMITED
TRANSIENT_DATABASE
LEASE_LOST
SCHEMA_DRIFT
INVALID_SOURCE_DATA
POLICY_BLOCKED
BUDGET_BLOCKED
AUTH_CONFIGURATION
PERMANENT_CONFIGURATION
DEPENDENCY_UNAVAILABLE
UNKNOWN_INTERNAL
```

Retry 여부와 human escalation을 category별로 결정한다.

## 8. Source fairness

한 source outage/backlog가 다른 source를 막지 않도록 queue partition/fair scheduling을 적용한다. 동시에 특정 기관/지역을 임의로 우선/후순위화하지 않는다.

## 9. Scheduler

Schedule은 DB state로 versioning한다. 중복 scheduler instance가 있어도 dedupe key/transaction으로 job이 중복 생성되지 않는다. Clock skew와 DST 영향을 피하려 UTC를 사용한다.

## 10. Reconciliation

Reconciler는 정상 경로를 대체하지 않는다. 탐지한 불일치는 evidence와 repair action을 기록한다.

- stale running jobs
- missing outbox
- missing public projection
- raw object without metadata / metadata without object
- source checkpoint gap
- expired idempotency
- retention due

## 11. Resource limits

- HTTP body/download size
- decompressed archive total/file count/depth
- parser CPU/time/memory
- DB query timeout
- job max runtime
- model tokens/cost
- log/event payload size

## 12. Operational commands

모든 repair/replay는 dry-run, scope, idempotency, audit, approval가 있어야 한다. “DB row 직접 수정” runbook은 금지한다.

## 13. Submission runtime

Submission API는 외부 입력 전용 rate limit, request-token/session validation, body/upload size limit, malware quarantine, no-store/no-referrer response, PII-safe logging을 갖는다. It never sends publication commands. 성공한 submission은 immutable receipt와 outbox event를 만들고 내부 intake processing job이 별도로 검증한다.

Response Portal은 token exchange 후 scoped HttpOnly session만 사용한다. Public Web은 correction/subscription action에 같은 Submission API를 쓰지만 response-request operation에는 접근하지 않는다. Operation-level capability와 separate client wrapper로 이 차이를 강제한다.

Submission/response outage는 Public API 읽기와 Review Console의 기존 사건 작업을 중단시키지 않는다. 반대로 Control outage가 외부 draft를 유실시키지 않도록 intake persistence와 receipt를 독립적으로 운영한다.
