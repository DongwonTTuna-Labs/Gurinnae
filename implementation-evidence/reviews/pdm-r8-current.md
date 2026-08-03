# PdM 독립 재검토 R8 (authority-v13 only)

`PDM_VERDICT: CHANGES_REQUIRED`

`REVIEWED_AT_UTC: 2026-07-19`
`AUTHORITY_ZIP_SHA256: 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
`ROLE: PDM / CORE_JOURNEYS / OPERATIONS / MEASUREMENT`

## 개선 확인

재생성된 artifact는 같은 plan 안에서 `journeyInstanceId`, expected version,
`currentObjectDigest`를 다음 edge에 전달한다. FLOW-01/02/04/05/06/10의
stage instance ID가 하나로 유지되고, 각 stage에 receipt/audit/outbox/event/
destination digest와 typed 40001 negative/무변경 count가 있다. PDM-003도
60초 window와 source/parser/rule의 명시적 `NOT_APPLICABLE` reason을 기록한다.

## Blocking findings

### PDM-R8-001 — persisted operationId binding이 여전히 없음 (P0)

`FLOWS`의 `operation_id`는 `collect()`가 artifact outer field에만 쓴다.
`run_stage()` SQL에는 operationId 인자가 없고, owner routine/audit/receipt row에
operationId를 전달하거나 readback하지 않는다. stage payload에도 operationId가
없다. 따라서 `publishCase`, `createResponseRequest`, `activateSubscription`,
`activateKillSwitch`는 실제 DB operation이 아니라 generator label이다.

통과 조건은 authority API operation을 실제 호출하거나 owner receipt에
operationId를 저장하고, 각 stage에서 persisted value가 authority operation과
일치하는 것을 assert하는 것이다. receiver function/edge ID는 operationId
binding을 대체하지 못한다.

### PDM-R8-002 — Flow 09가 subscription flow가 아님 (P0)

`flow-09`는 `J-01-E01` 한 stage, `PUB-004` destination만 실행한다. 이는
공개 사건 이해 journey의 첫 edge이며 authority Flow 09의
`createSubscription → verifySubscription → management token → get/update →
unsubscribe/suppression`을 전혀 실행하지 않는다. `operationId:
activateSubscription` outer label만으로 subscription receipt를 주장할 수
없다. Flow 09 전용 operation sequence와 invalid verification/replay/rate-limit
negative를 실행해야 한다.

### PDM-R8-003 — Flow 07/08/10의 semantic terminal gate 미충족 (P0)

- Flow 07은 J-07-E01/E04 두 edge만 실행하고 `PUB-004`에서 끝난다. rule
  draft/evaluation/gold-FP/shadow/quality gate/actual activation/monitor 또는
  rollback receipt가 없다.
- Flow 08은 J-10-E01/E02에서 `CAS-011`로 끝난다. OIDC/step-up/assurance,
  actor scope/SoD, high-impact authority command와 terminal receipt가 없다.
- Flow 10은 J-12 commercial qualification edges에서
  `OPS-001::configured-evidence-visible`로 끝난다. `activateKillSwitch`/
  `deactivateKillSwitch`, scope/expiry/two-person approval, degraded public
  notice, recovery/resume/postmortem이 실행되지 않았다.

Flow 03은 J-05/J-06/J-07 aggregate를 각각 실행하지만 aggregate 간 parent
  root/destination handoff link와 실제 `publishCase` command가 없어 별도
  P0 operation-binding/terminal gate 문제를 가진다.

### PDM-R8-004 — flow/PDM correlation ID 결속 부재 (P1)

`pdm-003-observability-20260719.json`에 correlation ID가 있으나 모든
`flow-*.json`에는 correlation ID가 없고 `run_stage()`/`collect()`에도 이를
전달하지 않는다. Flow 10 recovery receipt를 PDM artifact가 가리키지만 같은
trace/correlation graph임을 검증할 수 없다. 하나의 run correlation ID를 모든
stage input/receipt/audit/outbox/event/readback 및 PDM rows에 기록하고
validator가 동일성을 확인해야 한다.

### PDM-R8-005 — source-tree digest와 PDM pass 계산의 무결성 문제 (P1)

현재 `source_digest()`는 `git ls-files` 결과만 해시한다. generator 자체와
다수 source 파일이 아직 untracked인 현재 worktree에서는 최종 source-tree
archive와 digest가 동일하지 않다. `pdm-003` outer `pass`도 모든 row/assertion
결과가 아니라 `True`를 직접 기록한다. 각 row의 formula/window/NA reason 및
incident/PII assertions를 평가한 결과로 pass를 계산하고, archive에 들어갈
전체 source set을 canonical manifest로 해시해야 한다.

60초 window와 zero-observation `NOT_APPLICABLE`은 이전보다 올바르지만,
incident row가 여전히 generic stale handoff rejection이며 실제 kill-switch
lifecycle을 측정하지 않는 한 PDM-003 closure가 아니다.

## 재검토 조건

1. 실제 persisted operationId binding과 stage-level operation evidence.
2. Flow 09 전용 subscription lifecycle 및 Flow 07/08/10 terminal operations.
3. Flow 03 cross-aggregate parent linkage와 publication command receipt.
4. 공통 correlation ID의 flow/PDM readback.
5. archive-complete source digest와 계산된 PDM pass.

위 조건을 충족하기 전에는 `PDM_VERDICT: LGTM` 또는
`VERDICT: ARTIFACT_READY`를 발행할 수 없다.
