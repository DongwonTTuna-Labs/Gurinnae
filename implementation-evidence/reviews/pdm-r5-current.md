# PdM 독립 구현 재검토 R5 (authority-v13 only)

`PDM_VERDICT: CHANGES_REQUIRED`

`REVIEWED_AT_UTC: 2026-07-19`
`AUTHORITY_ZIP_SHA256: 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
`ROLE: PDM / CORE_JOURNEYS / OPERATIONS / MEASUREMENT`

## 판정 범위

규범은 위 SHA-256으로 고정한 `authority-v13` snapshot의
`specs/ui/flows/01..10-*.md`, `docs/11-operations-and-cost.md`,
`docs/13-observability-and-quality.md`만 사용했다. 현재 source/evidence와
테스트 코드를 읽었으며, 화면 trace·정적 catalog·fixture/mock 응답을
PostgreSQL durable receipt 증거로 인정하지 않았다.

## 현재 증거 감사

- `implementation-evidence/runtime-journey-receipts/product-structure-20260719.json`은
  PostgreSQL 18.4/SERIALIZABLE `ops.acceptance_runtime_probe_v1`의 8개
  product-structure 시나리오만 증명한다. 파일 자체도 flow 01–10 및 운영 SLI
  closure를 주장하지 않는다고 명시한다.
- `implementation-evidence/runtime-traces/*.json`은 94개 SSR/DOM 관찰이다.
  `pub-001`, `src-001`, `ops-001`, `rule-001`, `auth-001`, `rsp-001`,
  `cor-001` 모두 `ssrStatus: 200`이지만 section projection은 대부분
  `BLOCKED`이고 operation/DB/receipt/readback tuple이 없다.
- `tests/integration/acceptance/{case_lifecycle,correction_history,
  response_rights,final_delivery,source_freshness,schema_drift,
  budget_and_kill_switch,publication_gate}.rs`의 `runtime_probe`는
  `GURINNAE_ACCEPTANCE_RUNTIME_LAYERS_JSON` 문자열과 observation 경로만
  검사한다. 이는 실제 owner routine 또는 PostgreSQL transition을 호출하지
  않으므로 flow receipt가 아니다. `product_structure.rs` 및
  `journey_graph_addendum.rs` 등 `live_acceptance_probe` 사용 테스트도
  flow-specific branch/readback artifact를 보존하지 않는다.
- `tests/e2e/int-002-approval-journey.spec.ts`는 `127.0.0.1:29100` mock API와
  `_test/state`를 사용한다. UI approval contract에는 유용하지만 authority
  flow 08의 실제 DB receipt/audit/outbox/destination 증거로 사용할 수 없다.
- `implementation-evidence/` 아래에는 flowId/branchId/operationId와
  receipt·audit·outbox·destination readback을 포함한 flow 01–10 artifact가
  없고, 공통 correlation ID로 연결된 PDM-003 SLI window/incident recovery
  artifact도 없다.

## PDM-R5-001 — flow 01–10 durable receipt/readback 미충족 (P0)

authority flow는 정상 branch뿐 아니라 핵심 실패/복구 branch도 실제 runtime에서
실행하고, PostgreSQL transition·immutable receipt·audit/outbox/event·목적지
readback을 연결해야 한다. 현재는 해당 증거가 열 개 flow 모두 0건이다.

| flow | authority 정상/필수 negative branch | 현재 근거 | 판정 |
|---|---|---|---|
| 01 | 최신 사건 이해/claim locator + stale·evidence 제한·404/retraction history | 화면 trace만 존재; public operation/readback receipt 없음 | BLOCKED |
| 02 | citation→locator→reproducibility→checksum download + fixed revision | mock/SSR trace; rule/cohort/input digest와 download readback 없음 | BLOCKED |
| 03 | signal→triage→case→dual review→publish projection + gate/approval 실패 | acceptance source는 env readiness; operation IDs와 immutable snapshot readback 없음 | BLOCKED |
| 04 | request→token/session→scan→submit→RSP-006/intake + expired/replay/no publication mutation | submission UI tests 및 generated assertions뿐; 실제 response receipt chain artifact 없음 | BLOCKED |
| 05 | correction/retraction independent review→new revision→cache/API/download→notice + no-op/urgent branch | `correction_history.rs` env readiness; before/after revision 및 subscriber destination readback 없음 | BLOCKED |
| 06 | quarantine→schema diff→shadow parse→approval→bounded replay/checkpoint→freshness + drift failure | `source_freshness.rs`/`schema_drift.rs` source-only readiness; parser/checkpoint/freshness recovery receipt 없음 | BLOCKED |
| 07 | draft/eval/shadow/quality gate→independent activation→monitor/rollback + failed quality | dedicated live rule flow runner/artifact 없음; screen trace만 존재 | BLOCKED |
| 08 | auth/step-up/SoD expected-version command→receipt + denied/expired assurance | INT-002은 mock API; control-flow 실행 결과도 flow artifact로 보존되지 않음 | BLOCKED |
| 09 | verification→active→management/unsubscribe/suppression + invalid/replay/rate-limit | e2e submission mock; durable verification/suppression receipt/readback 없음 | BLOCKED |
| 10 | incident scope/runbook→kill switch activation/expiry/notice→recovery/resume/postmortem + SoD denial | `budget_and_kill_switch.rs` env readiness; kill-switch/recovery receipt와 public notice readback 없음 | BLOCKED |

필수 보완은 각 행에 대해 최소 `normal`과 authority가 명시한 핵심
`negative/recovery` 한 개를 실제 PostgreSQL runtime에서 실행하는 것이다. 각
JSON receipt에는 `authorityZipSha256`, `flowId`, `branchId`, `operationId`,
request `inputDigest`, actor/session scope, expected version, relation/schema
transition digest, immutable `receiptId`/`receiptDigest`, audit/outbox/emitted
event ID, destination readback digest, observed time, source-tree digest,
pass/fail 및 negative branch의 forbidden-mutation zero proof를 포함해야 한다.

## PDM-R5-003 — 운영 관측성 및 recovery 증거 미충족 (P0/P1)

authority v13의 SLO(공개/control/ingestion/publication), source/parser/rule/
agent/editorial/public metrics, trace chain, budget/queue/capacity, incident 및
kill-switch runbook을 실제 값으로 검증한 machine-readable artifact가 없다.
현재 `runtime-traces/ops-*.json`은 DOM trace이며 SLI window나 no-PII telemetry
검증을 하지 않는다.

다음 다섯 행을 하나의 clean runtime run과 동일한 correlation/trace ID로
수집해야 한다.

1. **Source** — fetch status/lag, new·updated·duplicate·quarantined,
   schema drift, checkpoint age, quota.
2. **Parser/normalization** — success/failure/warning, required-field/
   unknown-unit rates, provenance/confidence, replay mismatch.
3. **Rules/editorial/public** — rule version/run, triage/review/response/
   publication/correction latency, public latency/error/cache/freshness notice.
4. **Capacity/cost** — operation/job/source/rule correlation, PostgreSQL
   pool/query/WAL/backup, worker attempt/concurrency, outbox lag, SSR/build
   resources, provider/OCR calls and budget cap.
5. **Incident** — injected source/parser/provider/publication fault, alert/SLO
   window receipt, runbook action, switch scope/expiry/SoD receipt, degraded
   notice, recovery/resume verification, postmortem audit link.

각 row는 SLI window의 start/end, numerator/denominator, target, observed,
status/reason, metric schema/version, correlation ID 및 PII/secret label scan
결과를 가져야 한다. flow 10의 activation→degraded notice→recovery→resume
receipt는 flow receipt와 같은 correlation ID로 readback되어야 한다.

## 수정 후 재검토 조건

새 source/evidence가 위 10개 flow의 모든 branch와 5개 관측성 행을 채우고,
실제 PostgreSQL 재실행 로그·receipt digest·destination readback을 보존한 뒤
동일 authority SHA와 source-tree digest를 고정해 독립 재검토를 요청해야 한다.
그 전에는 `PDM_VERDICT: LGTM` 및 `VERDICT: ARTIFACT_READY`를 발행할 수 없다.
