# PdM R6 flow-stage execution contract (authority-v13 only)

이 문서는 구현 코드가 아니라 다음 flow evidence 재생성에 사용할 최소 실행
계약이다. 규범은 authority-v13 `specs/ui/flows/01..10-*.md`, 해당 authority
screen/API operation contract뿐이다. 각 stage는 실제 operationId를 실행하고
request/response와 DB row receipt·audit·outbox·event·destination readback을
같은 correlation ID에 결속해야 한다.

| Flow | 최소 정상 stage sequence | 필수 flow-specific negative/recovery |
|---|---|---|
| 01 | `getPublicCase` → `listCaseRevisions` → `getPublicCaseRevision` → `getCaseReproducibility` 및 claim locator readback | stale source/evidence limitation 또는 404/retraction; history/public projection 무변경 |
| 02 | `getPublicCase` → `getCaseReproducibility` → `downloadCaseReproducibility` → fixed `getPublicCaseRevision` | correction/retraction notice 유지 또는 checksum/license mismatch 거부 |
| 03 | `listSignals` → `getSignalTriageView` → `triageSignal(PROMOTE_TO_CASE)` → case workspace → `createHypothesis`/`addEvidence`/`verifyEvidence` → `addClaim`/`validateClaims` → response composer/save/create → response excerpt approval → readiness/snapshot → 독립 reviewer 2인의 `submitReview` → publication preview/confirmation/`publishCase`/`getPublicationReceipt` → public case readback | gate fail, stale snapshot, non-independent reviewer; publish/projection zero mutation |
| 04 | response composer/save/create → `exchangeResponseAccessToken`/`verifyResponseAccess` → request/draft read → attachment upload/finalize(CLEAN) → preview/`submitResponse` → receipt token exchange/`getResponseReceipt` | expired/other token, scan REJECTED, pre-scan submit; publication 상태 무변경 |
| 05 | correction request → queue/assign/triage → workspace/draft → `createCorrection` 또는 resolve → 독립 review → correction/public revision/API/download/notice readback | `resolveCorrectionRequest(NO_CHANGE)` 및 urgent temporary restriction; old revision immutable |
| 06 | `getSchemaDrift` → `approveSchemaMapping` → `estimateBackfill` → `startBackfill` → checkpoint/dedupe → source health/public freshness readback | schema mismatch/quarantine, approval denial, stale checkpoint; checkpoint advance zero |
| 07 | rule version/draft → `runRuleEvaluation` → `startRuleShadow` → evaluation/readiness → `activateRuleVersion`/schedule → monitoring 또는 rollback readback | quality gate/SoD/stale version 거부; active version unchanged |
| 08 | `startOidcLogin` → 필요 시 `startStepUpAuthentication` → high-impact authority command(예: `activateRuleVersion` 또는 `publishCase`) with expected-version/idempotency → terminal receipt | failed/expired step-up, SoD denial, stale version; domain/audit-success/outbox zero |
| 09 | `createSubscription` → `verifySubscription` → management-token exchange → `getSubscription` → `updateSubscription` → `unsubscribe` → suppression readback | invalid/expired verification, replay/rate-limit, unsubscribe idempotency |
| 10 | `getOperationsOverview` → `listKillSwitches` → step-up/second approver → `activateKillSwitch(scope,reason,expiry)` → affected operation rejection + public degraded notice → recovery verify → `deactivateKillSwitch` → operations/history/postmortem readback | missing reason/expiry, broad switch single approver, stale version; switch mutation zero |

## Receipt acceptance predicates

각 정상/negative branch artifact는 다음을 모두 가져야 한다.

1. authority SHA, source-tree/archive digest, flow/branch ID, correlation ID,
   실제 operationId sequence, request input digest, actor/session scope,
   expected version.
2. 각 mutation operation의 persisted receipt ID/digest와 해당 relation
   transition digest, audit event ID, outbox event ID, emitted event ID.
3. 최종 목적지 API/projection/read model의 readback digest 및 observed time.
4. negative branch의 authority-specific error code/SQLSTATE와 forbidden
   mutation count **및** before/after row digest 동일성.
5. operationId는 generator label이 아니라 persisted command/audit row의
   값을 읽어 검증해야 하며, `pass`는 모든 assertion을 실제로 평가해 계산한다.

## PDM-003 acceptance predicates

source, parser/normalization, rules/editorial/public, capacity/cost,
incident/recovery 다섯 행은 동일 correlation ID와 실제 non-zero observation
window(또는 명시적 `NOT_APPLICABLE`/`UNKNOWN` reason)를 가져야 한다. 각 행의
start/end, formula, numerator/denominator, target, observed, reason 및 PII/
secret scan을 검증한다. `windowStart == windowEnd` 단일 snapshot 또는
source/rule 관측 0건을 `KNOWN/NONE`으로 기록한 artifact는 통과시키지 않는다.
Flow 10은 실제 kill-switch activation/deactivation, scope/expiry/SoD,
degraded notice, recovery/resume, postmortem audit을 같은 correlation ID로
연결해야 한다.
