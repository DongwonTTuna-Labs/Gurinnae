# PdM 독립 리뷰 R10 — 2026-07-19 17:51 UTC

검토 대상: authority-v13 SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`, 최신
`scripts/generate_pdm_flow_evidence.py`, 그리고 17:49 UTC에 생성된
`implementation-evidence/runtime-journey-receipts/flow-01..10` 및 PDM-003
artifact. 이전 authority와 별도 Gurinnae 자료는 사용하지 않았다.

## 닫힌 항목

- Flow-01..10 artifact의 `correlationId`는 현재 모두
  `f6167a99-4b0b-4997-83e5-0c3eaad44734`로 결속되어 있다.
- Flow-09는 `createSubscription → verifySubscription →
  exchangeSubscriptionManagementToken → getSubscription → updateSubscription →
  unsubscribe`를 실행하고 `UNSUBSCRIBED` readback 및 invalid verification
  (`28000:subscription_verification_invalid`) negative를 기록한다.
- 모든 flow의 generic handoff branch에는 receipt/audit/outbox, instance
  continuity, stale-version `40001` 무변경 증거가 있다.

## Blocking findings

### PDM-R10-001 — expected authority operation과 persisted operation 불일치 (P0)

`flow-01` stage는 outer `operationId: getPublicCase`이지만
`normal.stages[0].operationResponse.operationId`는
`decideJourneyHandoff`이다. 같은 문제가 publishCase, activateRuleVersion,
submitActionDecision 등 모든 generic stage에 있다. generator의
`operationIdPersisted`는 response가 `decideJourneyHandoff`인지 만 검사하며,
outer expected operation과의 equality를 검사하지 않는다. `operationBinding`에도
persisted operation ID가 없다. 따라서 named authority operation이 실행됐다는
증거가 아니라 generic handoff dispatcher가 실행됐다는 증거다.

### PDM-R10-002 — Flow 03–08 semantic owner terminal 미충족 (P0)

Flow-03은 세 aggregate를 독립적으로 ACK했지만 parent/root handoff 링크와 실제
`publishCase` command receipt가 없다. Flow-04/05/06도 response submission,
correction notification, schema backfill/freshness owner operation을 호출하지
않는다. Flow-07은 두 generic edges만(`PUB-004` 종료)이고 rule draft/evaluation/
shadow/quality/activation/rollback receipt가 없다. Flow-08은 두 generic edges만
(`CAS-011` 종료)이고 OIDC role/scope, assurance/step-up, SoD 및 high-impact
command receipt가 없다.

### PDM-R10-003 — Flow 09/10 named operation binding 및 lifecycle 증거 부족 (P0)

Flow-09의 subscription owner 함수 sequence 자체는 정상이나 `operationId`를
persisted audit/outbox/command receipt에 결속하지 않는다. Flow-10은
`collect_kill_switch()`에서 `ops.kill_switches`를 직접 INSERT/UPDATE한다.
`activateKillSwitch`/`deactivateKillSwitch` command/API, audit/outbox receipt,
expiry/reason SoD/two-person approval, public degraded notice, recovery/resume,
postmortem의 실행 및 readback이 없다.

### PDM-R10-004 — PDM-003 correlation 및 source digest artifact 불일치 (P1)

Flow artifacts는 동일 correlation ID지만 PDM-003은
`c3293fff-9f4f-42ed-8dc3-4f5d84cf7fbf`로 다르다. sourceTreeDigest도 flow-01..08,
flow-09/10, PDM artifact가 서로 달라 최종 source tree snapshot을 공통으로
검증할 수 없다. generator가 correlation 수정된 뒤 artifact를 다시 생성하고,
최종 archive source set 고정 후 모든 artifact digest를 동일하게 만들어야 한다.

### PDM-R10-005 — PDM row별 계산된 pass/SLI 근거 부족 (P1)

PDM-003 rows에 개별 `pass` 필드가 없고 outer `pass`는 flow pass와 status enum만
확인한다. source/parser/rule rows는 관측 0건을 `NOT_APPLICABLE`로 처리하며
capacity/incident 값은 synthetic counters다. 각 row의 formula, observation,
NA reason, PII/incident assertion 결과를 계산해 outer pass에 반영해야 한다.

## 판정

```text
PDM_VERDICT: CHANGES_REQUIRED
```

위 P0/P1 항목을 닫고, generator 수정 후 동일 source digest/correlation의
artifact를 재생성해 독립 재검토하기 전에는 `PDM_VERDICT: LGTM`을 발행할 수 없다.

