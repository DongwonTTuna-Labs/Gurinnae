# PdM 독립 리뷰 R9 — 2026-07-19

검토 대상은 authority-v13 SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`와 현재
`implementation-evidence/runtime-journey-receipts`이다. 이전 authority나 별도
Gurinnae 자료는 판단 근거로 사용하지 않았다.

## 현재 관찰

`flow-01`부터 `flow-03`까지만 `correlationId`가 있고 `flow-04`부터 `flow-10`은
`correlationId: null`이다. PDM-003의 correlation ID는 흐름 ID와 다른 UUID이다.
따라서 단일 실행의 flow → audit/outbox/receipt → observability graph를 추적할 수
없다.

`flow-09-20260719.json`은 `J-01-E01`/`PUB-004`를 실행하고
`activateSubscription`이라는 외부 label만 기록한다. authority가 요구하는
`createSubscription → verifySubscription → exchange management token →
get/update → unsubscribe/suppression readback`의 증거가 아니다. 현재 generator에는
`collect_subscription()`이 추가되어 있으나 artifact의 mtime(17:32 UTC)이 generator
(17:35 UTC)보다 이전이므로 아직 반영되지 않았다.

`flow-10` artifact는 `OPS-004` commercial edges로 끝나며 실제 kill-switch
row의 activate/deactivate 상태 전이를 담지 않는다. 최신 generator의
`collect_kill_switch()`도 아직 artifact에 반영되지 않았다.

## Blocking findings

### PDM-R9-001 — persisted operationId binding 없음 (P0)

`collect()`는 `operationId`와 `operationBinding`을 artifact에 주입하지만,
`run_stage()` SQL은 operation ID를 owner routine에 전달하지 않는다. binding은
receiver function/edge ID, audit/outbox UUID의 존재만 확인한다. 이는
`publishCase`, `createResponseRequest`, `activateSubscription`,
`activateKillSwitch`가 실제 authority operation으로 실행됐다는 증거가 아니다.
authority dispatcher 또는 해당 owner API 호출 후 response/audit/outbox의 persisted
operationId를 readback하고 `actual == expected`를 assert해야 한다.

### PDM-R9-002 — Flow 09 artifact가 잘못된 journey (P0)

subscription-specific owner sequence 및 invalid verification/replay/rate-limit
negative와 suppression readback이 artifact에 없다.

### PDM-R9-003 — Flow 07/08/10 semantic terminal gate 미충족 (P0)

Flow 07은 rule draft/evaluation/shadow/quality/activation/monitor/rollback,
Flow 08은 OIDC/step-up/SoD/high-impact command receipt, Flow 10은 incident
detection/scope/activate/degraded notice/recovery/deactivate/postmortem의 실제
owner receipts가 없다. generic journey handoff edge만으로 terminal gate를 닫을 수
없다.

### PDM-R9-004 — correlation graph 단절 (P1)

단일 run correlation UUID를 모든 flow stage와 PDM rows에 전달하고, persisted
receipt/audit/outbox/event/readback에서 동일 ID를 검증해야 한다. 현재는 flow와
PDM-003이 서로 다른 UUID 또는 null이다.

### PDM-R9-005 — PDM pass 및 archive digest 검증 미완료 (P1)

PDM-003 outer `pass`는 row별 formula/assertion의 결과를 계산하지 않고 flow pass와
상태 enum만 확인한다. source digest가 최종 archive source set과 동일하다는
검증도 남아 있다. 최종 archive canonical manifest를 기준으로 digest를 생성하고,
각 PDM row/PII/incident/NA assertion을 실제 계산해 outer pass를 산출해야 한다.

## 판정

위 P0/P1 조건이 닫힐 때까지 PdM 판정은 다음과 같다.

```text
PDM_VERDICT: CHANGES_REQUIRED
```

