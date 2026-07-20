# PdM R4 flow/observability evidence contract (authority-v13 only)

이 문서는 구현 변경 지시가 아니라 PDM-R3-001/003을 닫기 위한 증거 계약이다.
규범은 `authority-v13/specs/ui/flows/01..10-*.md`,
`authority-v13/docs/11-operations-and-cost.md`,
`authority-v13/docs/13-observability-and-quality.md`뿐이다.

## Flow receipt matrix

각 행은 최소 한 개의 정상 branch와 authority 문서가 요구하는 핵심 실패/복구
branch를 실제 PostgreSQL/application runtime에서 실행해야 한다. 화면 trace,
mock response, source-only assertion은 이 표의 receipt를 대체하지 못한다.

| Authority flow | Current executable starting points | Required live proof |
|---|---|---|
| 01 public case comprehension | `tests/e2e/acceptance/public-comprehension.spec.ts`, `tests/integration/public-flow.py` | `getPublicCase`/revision/read evidence operation ID, correction-current readback, claim locator, freshness/unknown reason, public destination response |
| 02 journalist reproduction/citation | `tests/e2e/acceptance/public-comprehension.spec.ts` (locator case), `tests/integration/public-flow.py` | citation→locator→`getCaseReproducibility`→download chain; rule version/cohort/input digest, checksum/license, fixed revision URL readback |
| 03 signal to publication | `tests/integration/acceptance/case_lifecycle.rs`, `publication_gate.rs`, `tests/e2e/int-002-approval-journey.spec.ts` | signal/triage/task/case/review/publish operation IDs; gate re-evaluation, dual approval, immutable snapshot receipt, projection readback, audit/outbox/event IDs |
| 04 response request/submission | `tests/integration/acceptance/response_rights.rs`, `final_delivery.rs`, `tests/integration/submission-flow-cases-a.ts`, `tests/e2e/submission-routing.spec.ts` | scoped token/session hash, file-scan terminal receipt, submission receipt, intake destination, no publication mutation, replay/expired-token negative receipt |
| 05 correction/retraction | `tests/integration/acceptance/correction_history.rs`, `tests/integration/submission-flow-cases-a.ts`, `tests/e2e/submission-routing.spec.ts` | before/after revision, independent review receipt, immutable old revision, cache/API/search/download readbacks, subscriber notice and root-cause receipt |
| 06 source schema drift | `tests/integration/acceptance/source_freshness.rs` | quarantine→schema diff→shadow parse→approval→bounded replay/checkpoint; parser result digest, dedupe receipt, freshness recovery readback, stale notice lifecycle |
| 07 rule evaluation/activation | authority flow only; no dedicated current `tests/integration/acceptance/*rule*` suite found | draft version, gold/FP evaluation, shadow run, quality decision, independent activation receipt, production monitoring sample, rollback target/effective time |
| 08 auth/reauth/high-impact action | `tests/integration/identity-flow.ts`, `tests/e2e/int-002-approval-journey.spec.ts`, `tests/integration/control-flow.py` | actor/scope/session, step-up assurance, expected-version/idempotency, server gate/SoD decision, audit + terminal receipt; denial and expired assurance negative readback |
| 09 subscription management | `tests/integration/submission-flow-cases-b.ts`, `tests/e2e/submission-routing.spec.ts`, `tests/e2e/acceptance/submission-boundary.spec.ts` | create→verification→active→management→unsubscribe, endpoint/session hashes, verification receipt, suppression/readback, replay/rate-limit negative receipt |
| 10 incident/kill switch | `tests/integration/acceptance/budget_and_kill_switch.rs`, `tests/integration/identity-flow.ts` | incident scope/runbook, two-person approval where required, switch activation/expiry, public degraded notice, recovery verification, resume and postmortem audit receipt |

### Per-flow receipt schema

Each receipt artifact must contain: `authorityZipSha256`, `flowId`, `branchId`,
`operationId`, request `inputDigest`, actor/session scope, `expectedVersion`,
PostgreSQL relation transition and schema digest, immutable `receiptId` and
`receiptDigest`, `auditEventId`, `outboxEventId`, emitted event ID, destination
readback digest, `observedAt`, source-tree digest, and pass/fail disposition.
Negative branches must contain the expected closed error/reason and prove no
forbidden mutation occurred.

## PDM-003 observability matrix

Use one clean runtime run with a shared trace/correlation ID and retain a machine-
readable artifact, not just dashboard screenshots. Required rows:

1. Source: fetch requests/status, lag, records new/updated/duplicate/quarantined,
   schema drift, checkpoint age, quota.
2. Parser/normalization: success/failure/warning, required-field missing,
   unknown unit/category, provenance coverage, confidence, replay mismatch.
3. Rules/editorial/public: rule version/run and triage timing; queue/review/
   response/publication/correction latency; public latency/error/cache and
   freshness notice.
4. Runtime capacity/cost: operation/job/source/rule-version correlation,
   PostgreSQL pool/query/WAL/backup, worker attempt/concurrency, outbox lag,
   SSR request/build resource, provider/OCR calls and budget cap.
5. Incident: injected source/parser/provider or publication fault, alert/SLO
   window receipt, runbook action, kill-switch scope/expiry/SoD receipt,
   public degraded notice, recovery verification and postmortem link.

### LGTM conditions

PDM-R3-001 closes only when all ten flow rows have the normal and required negative
receipt chains with durable destination readback. PDM-R3-003 closes only when all
five observability rows have live SLI window evidence, no PII/secret labels, and
incident/kill-switch recovery receipts linked by the same correlation ID. Until
then the PdM verdict remains `CHANGES_REQUIRED`.
