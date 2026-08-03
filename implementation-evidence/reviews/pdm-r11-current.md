# PdM 독립 리뷰 R11 — 2026-07-19 18:04 UTC

최신 flow-01..10 및 PDM-003 artifact를 authority-v13 SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5` 기준으로
독립 확인했다.

## 통과한 항목

- 10개 flow와 PDM-003의 `correlationId`가
  `9c128a4d-31dc-4f2d-9581-f014a513a8e1`로 동일하다.
- 모든 artifact의 `sourceTreeDigest`가
  `22dfe31335c0d34cdf0ed7e6c090c11a8ee179564607bf2329431a25b02413bc`로 동일하다.
- Flow 07: draft, FULL evaluation, shadow, quality gate, activation, monitoring,
  failed-quality block, rollback의 owner/audit/outbox 증거가 있다.
- Flow 08: OIDC login/step-up, missing/expired step-up rejection, SoD denial,
  APPROVED terminal state 및 receipt가 있다.
- Flow 09: subscription 6단계, UNSUBSCRIBED readback, invalid verification
  negative가 있다.
- Flow 10: incident, activate/deactivate command receipts, narrow scope/expiry,
  stale-version negative, audit/outbox 및 recovery state가 있다.
- PDM-003 각 row의 formula/pass와 outer pass가 계산된다.

## 남은 blocker

### PDM-R11-001 — Flow 01–06 named operation binding 불일치 (P0)

각 stage의 outer `operationId`는 `getPublicCase`, `getCaseReproducibility`,
`publishCase`, `createResponseRequest`, `submitCorrectionRequest`,
`approveSourceSchemaMapping`이지만, 동일 stage의
`persistedOperationId`와 `operationResponse.operationId`는 모두
`decideJourneyHandoff`다. `operationBinding.bindingVerified`는 receiver edge와
`decideJourneyHandoff`만 검사해 expected named operation과의 equality를
검사하지 않는다. named authority API를 실제 실행하고 persisted response/audit/
outbox operation ID를 readback하거나, 최소한 mismatch를 hard-fail해야 한다.

### PDM-R11-002 — Flow 03 cross-aggregate linkage 및 publication command 없음 (P0)

J-05/J-06/J-07 stages의 `parentJourneyInstanceId`, `parentRootId`, `relation`이
모두 null이며 각 aggregate가 독립 생성됐다. 최종 `PUB-004::public-smoke-receipt`
generic handoff는 실제 `publishCase` command/public projection receipt를
증명하지 않는다.

### PDM-R11-003 — Flow 04–06 semantic owner operation receipts 없음 (P0)

Flow 04는 response request/session/attachment clean scan/submit receipt,
Flow 05는 correction revision/public API/download/notification, Flow 06은
schema mapping/backfill/checkpoint/dedupe/freshness owner receipts를 포함하지
않고 generic handoff edges만 기록한다.

### PDM-R11-004 — Flow 09 owner operation persistence 부족 (P1)

정상 sequence와 상태 readback은 있으나 artifact에는 각 subscription operation의
request/operation ID, audit/outbox 또는 owner receipt가 없다. named operation을
실행했다는 durable evidence로 보강해야 한다.

## 판정

```text
PDM_VERDICT: CHANGES_REQUIRED
```

Flow 01–06의 named operation/aggregate semantic evidence가 닫히기 전에는 PdM
LGTM 또는 최종 `ARTIFACT_READY`를 발행할 수 없다.

