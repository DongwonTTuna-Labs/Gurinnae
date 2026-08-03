# PdM 독립 재검토 R7 (authority-v13 only)

`PDM_VERDICT: CHANGES_REQUIRED`

`REVIEWED_AT_UTC: 2026-07-19`
`AUTHORITY_ZIP_SHA256: 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
`ROLE: PDM / CORE_JOURNEYS / OPERATIONS / MEASUREMENT`

## 확인된 개선

최신 artifacts는 이전 버전보다 나아졌다.

- flow별 authority edge 목록과 최종 destination node가 저장된다.
- 각 stage에서 PostgreSQL start/request/ACK owner routine을 실행하고,
  receipt/audit/outbox/event/destination digest를 readback한다.
- negative branch가 typed `{sqlstate: 40001, message: journey_version_conflict}`
  로 기록되고 receipt count가 증가하지 않는다.
- PDM-003 window가 60초이며, source/parser/rule 관측 없음은
  `NOT_APPLICABLE`과 reason으로 fail-closed 기록된다.

그러나 아래 blocker 때문에 LGTM은 발행할 수 없다.

## PDM-R7-001 — stage receipt는 하나의 chain이 아님 (P0)

`run_stage()`는 **각 edge마다** `start_journey_instance_v1()`를 새로 호출한 뒤
그 새 instance에서 request/ACK를 수행한다. 따라서 같은 flow의 stage들은
서로 다른 `journeyInstanceId`와 version 1→3을 갖고, 이전 stage의 receipt,
parent digest, instance ID/version을 다음 stage에 전달하지 않는다. artifact의
`stageIndex`는 배열 순번일 뿐 DB sequence/parent edge가 아니다. 예를 들어
FLOW-01 네 stage의 instance ID가 모두 다르다. 이는 권위 flow를 연속 실행한
것이 아니라 각 edge를 독립적으로 실행한 것이다.

필수 수정: flow마다 하나의 journey instance를 시작하고, edge ACK 후 반환된
instance ID, version, current node, receipt digest를 다음 edge request의
expected version/parent digest로 사용한다. artifact에 parent receipt ID/digest,
prior sequence, same instance ID와 최종 sequence를 저장하고 DB readback으로
연속성을 assert해야 한다.

## PDM-R7-002 — 실제 operationId binding 없음 (P0)

현재 `FLOWS`의 `operation_id`는 `collect()`에서 artifact 외부 필드로만
기록된다. `run_stage()`에는 operationId 인자가 없고 SQL routine이나 audit
insert에 전달하지 않는다. 각 stage payload에도 operationId가 없다. 즉
`publishCase`, `createResponseRequest`, `activateSubscription`,
`activateKillSwitch` 등의 값은 generator label이며 persisted command/query
receipt와 일치하는지 검증되지 않는다.

필수 수정: authority API operation을 실제로 호출하거나 owner routine이
operationId를 받아 persisted command/audit/receipt row에 저장하게 하고,
artifact는 그 row를 다시 읽어 `actualOperationId == authorityOperationId`를
assert해야 한다. label만 있는 artifact는 flow evidence로 인정하지 않는다.

## PDM-R7-003 — 일부 flow stage/operation은 authority 의미와 불일치 (P0)

| Flow | 현재 artifact | authority 누락 |
|---|---|---|
| 03 | J-05/J-06/J-07 edge handoff 묶음 | 실제 signal triage, evidence/claim gate, 독립 review 두 명, `publishCase` command와 publication receipt 실행 없음 |
| 04 | J-03 edge handoff 7개 | response token exchange, access verification, draft, attachment CLEAN scan, `submitResponse`, RSP-006 receipt 없음 |
| 05 | J-08 edge handoff 4개 | correction draft/review/new revision 및 API/download/search/notification readback 없음 |
| 06 | J-09 edge handoff 4개 | parser mismatch quarantine, schema mapping/shadow, backfill estimate/start, checkpoint/dedupe 없음 |
| 07 | J-07-E01/J-07-E04 두 개 | rule draft/evaluation/shadow/quality gate/activation/monitor 또는 rollback 없음 |
| 08 | J-10-E01/J-10-E02 | OIDC/step-up, actor scope, SoD policy와 high-impact command receipt 없음 |
| 09 | J-01-E01 하나, destination `PUB-004` | subscription create→verify→management→update/unsubscribe/suppression 전부 없음; journey 자체도 잘못됨 |
| 10 | J-12 commercial qualification edges | `activateKillSwitch`/`deactivateKillSwitch`, scope/expiry/SoD, degraded notice/recovery 없음 |

Edge 이름/목적지 문자열이 화면 flow와 비슷하다는 것만으로 실제 operation
효과가 발생했다고 추론할 수 없다.

## PDM-R7-004 — correlation ID가 flow receipts에 결속되지 않음 (P1)

`pdm-003-observability-20260719.json`에는 correlation ID가 있지만 각
`flow-*.json`에는 correlation ID 필드가 없고 generator의 `collect()`/`run_stage()`
에도 correlation 값을 전달하지 않는다. 따라서 incident recovery와 flow
stage receipt가 같은 trace/correlation graph에 연결됐다는 증거가 없다.

필수 수정: 하나의 run correlation ID를 모든 flow stage의 input/receipt/audit/
outbox/event/readback와 PDM rows에 저장하고, artifact validator가 모든 ID가
동일함을 검증해야 한다.

## PDM-R7-005 — PDM-003은 구조적 snapshot이며 실제 SLI와 불완전하게 연결됨 (P1)

60초 window와 `NOT_APPLICABLE` reason은 개선이다. 다만 source/parser/rule의
실제 관측값은 모두 0이고, `pdm-003` generator의 outer `pass`는 항상 `True`를
기록한다. capacity row는 audit/outbox 수와 DB size만 읽으며 authority
`docs/11`의 latency/lag/error-budget/provider/worker metrics를 측정하지 않는다.
incident row는 `stale-expected-version` generic handoff 거부를 runbook으로
기록할 뿐 실제 kill-switch activation/deactivation 및 public degraded notice
를 증명하지 않는다.

필수 수정: PDM rows의 각 formula/target에 실제 observation 또는 명시적
NA/UNKNOWN validator를 적용하고, outer pass를 모든 row/assertion의 결과로
계산한다. Flow 10의 실제 switch/notice/recovery receipt와 같은 correlation
ID로 연결해야 한다.

## 재검토 조건

1. 하나의 journey instance와 parent/version/digest를 이어가는 연속 edge chain.
2. persisted operationId와 authority API operation의 exact binding readback.
3. 각 flow의 authority-specific terminal operations와 negative/recovery branch.
4. 모든 stage와 PDM-003 rows에 동일 correlation ID.
5. actual kill-switch lifecycle, SLI assertion 및 계산된 pass 값.

위 조건을 source-tree digest와 함께 독립 재검증하기 전에는 `PDM_VERDICT:
LGTM` 또는 `VERDICT: ARTIFACT_READY`를 발행할 수 없다.
