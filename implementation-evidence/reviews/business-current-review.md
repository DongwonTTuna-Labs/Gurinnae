# Business-model review — current source (2026-07-20)

검토 범위는 첨부된 v13 authority ZIP(sha256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`)과 그
authority를 구현한다고 선언한 현재 source tree이다. 이전 Gurinnae 자료와
이전 review의 판정은 근거로 사용하지 않았다. 이 문서는 read-only review이며
소스를 수정하지 않았다.

## 판정

`BUSINESS_VERDICT: CHANGES_REQUIRED`

authority가 현재 허용하는 사업 단계는 `docs/02-governance-and-revenue.md`의
Stage 1 public-benefit pilot이다. 공개 사실·근거·정정·소명·기본 알림은 무료여야
하고, 후원·고객·광고가 조사 우선순위나 공개 판단을 바꿀 수 없다. PUB-023의
funding disclosure는 이 경계를 지키지만, 운영 비용/내부 AI 비용을 사업 의사결정에
쓸 수 있는 현재 경로와 최신 증거가 닫히지 않아 전체 business LGTM을 줄 수 없다.

## 검토 매트릭스

| 축 | 판정 | 현재 근거 |
|---|---|---|
| 대상 고객·가치 전달 | Stage 1 범위 PASS | authority의 시민·기자·연구자 가치와 무료 공개 근거/정정 경계가 `docs/27-product-strategy-and-principles.md`와 public 화면에 있다. |
| 획득·활성화·유지 | Stage 1 범위 PASS, 유료 성과 주장 금지 | authority는 회원/데이터 상품·workspace·audit SaaS를 Stage 2/3로 둔다. PUB-029 구독은 무료 검증→scoped subscription 경로이지 매출/retention 증거가 아니다. |
| 수익·편집 독립성 | PASS (fail-closed) | `services/public-api/src/service/public_funding.rs`는 서명된 disclosure가 없을 때 금액·비용·case별 이해상충을 `UNKNOWN`으로 둔다. `pub-023` trace는 6개 section READY이며 pay-to-remove/priority coupling이 없다. |
| 비용·예산 운영 | **BLOCKED** | OPS-004가 실사용/예측/한도/경보/변경 이력을 완전한 사실로 연결하지 못하고 현재 trace는 6개 section 전부 BLOCKED다. (BM-BUDGET-001) |
| 비용 export·정산 | **BLOCKED** | `exportCostReport`가 binary report/receipt가 아니라 agent run 집계 JSON만 반환한다. (BM-EXPORT-001) |
| 증거 재현성 | **BLOCKED** | OPS-004 최신 source 변경 이후 trace/manifest가 동일 source digest로 재생성되지 않았다. (BM-EVIDENCE-001) |

## Blocking findings

### BM-BUDGET-001 — UNKNOWN을 0으로 내려 false-green 비용 판단 가능

현재 `services/control-api/src/service/query_business.rs:12-23`는 budget limit,
cost event가 없거나 통화가 섞여도 `dailyLimit`, `dailyUsed`, `monthlyLimit`,
`monthlyUsed`를 문자열 `"0"`으로 만든다. 상태는 `UNKNOWN_*`으로 표시되지만
숫자 자체는 `UNKNOWN`과 결합되지 않는다. `dailySeries/topCases`도
`max(currency)`를 선택하고 단일 통화 행만 남기는 방식이다(같은 파일
31-49). 운영자는 비용이 0인지 관측이 없는지 즉시 구별할 수 없다.

authority `docs/11-operations-and-cost.md`의 초기 guardrail은 작업 시작 전
reservation, 실제 비용 settlement, cap 도달 시 `PAUSED_POLICY`와 사람 승인,
override reason/amount/expiry/approver를 요구한다. 현재 BudgetOverview query는
reservation/settlement ledger 또는 이 중단·override receipt를 읽지 않는다.

또한 authority BudgetOverview의 closed 응답에는 forecast/soft-hard-fallback
limit/threshold alert/approver-reason 필드가 없고, 현재 mapper는 이 필드가
없으면 `FORECAST_OWNER_FACT_MISSING`을 생성한다
(`packages/ui/src/view-models/ops-004.ts:127-176`). 최신 runtime trace
`implementation-evidence/runtime-traces/ops-004.json:11-43`은 envelope,
spend, forecast, limits, alerts, changes 모두 `BLOCKED`이다. 이는 안전한
unknown 관찰 한 건일 뿐 populated·empty·mixed-currency·stale 상태를 운영자가
사업 비용과 다음 조치를 판단할 수 있게 만든 증거가 아니다.

종료 조건:

1. 관측·한도·통화·기간·freshness가 없는 금액은 숫자 `0`이 아니라 nullable
   값과 구체적 `UNKNOWN/BLOCKED` reason/owner action으로 반환한다.
2. BudgetOverview authority schema와 generated client를 유지하면서, forecast/
   limits/alerts/changes가 필요하면 authority가 허용한 screen-owned closed
   projection 또는 별도 approved operation으로 계약을 닫는다.
3. clean PostgreSQL 18.4에서 populated, no-observation, mixed-currency,
   stale/reconciliation 케이스를 실행하고 compact/wide SSR trace를 같은
   source digest로 저장한다.

### BM-EXPORT-001 — 비용 보고서가 실제 비용 원장/바이너리 receipt로 닫히지 않음

authority `exportCostReport`는 `/v1/internal/queries/export-cost-report`의
`BinaryDownload`이며 query에 지정된 기간·groupBy·format에 대한 binary body와
권리/재현 metadata를 요구한다(`specs/api/operation-contracts.yaml:8318-8385`,
`specs/ui/screens/OPS-004.md`). 현재
`services/control-api/src/service/query_business.rs:128-158`는
`ops.agent_runs.actual_cost/max_cost`를 단순 합산하고
`{"id","status","version"}`만 반환한다. 파일 bytes, media type, checksum,
source/correction digest, usage/settlement membership가 없다. 이는 UI에서
`READY`로 보일 수 있는 경우에도 회계·운영자가 검증 가능한 비용 export가
아니다.

동일한 metadata-only shape가 `crates/api-contracts/src/control_api.rs`의
`exportCostReport` `response_json`에도 고정되어 있어, 단순 handler 수정만으로
끝나는 문제가 아니다. generated client/HTTP download 경계까지 함께 닫아야 한다.

종료 조건:

1. reservation/settlement/provider usage와 correction head를 기준으로 exact
   period/groupBy/format의 deterministic report를 materialize한다.
2. binary body와 filename/media type/byte length/checksum/rights/revision
   metadata를 generated response 및 server-only download 경계에 연결한다.
3. empty, unknown, partial, mixed currency, corrected row를 각각 실행해
   `EMPTY`와 `UNKNOWN/BLOCKED`를 구분하고 report digest를 audit에 남긴다.

### BM-EVIDENCE-001 — 최신 source와 동일 digest의 business witness 부재

`implementation-evidence/runtime-traces/ops-004.json`의 관측 시각은
2026-07-19이며 전 section이 BLOCKED이다. `pub-023`의 같은 날짜 trace는 6개
section READY이지만, 현재 source에는 funding/query/UI 변경이 다수 남아 있어
이 두 trace를 현재 최종 tree의 증거로 재사용할 수 없다. 현재
`MANIFEST.sha256`도 source가 변경될 때마다 재생성되어야 한다.

`implementation-evidence/runtime-journey-receipts/business-model-20260719.json`
은 스스로 “implementation-addendum evidence이며 authority-v13 monetization
approval이 아님”이라고 명시한다. 따라서 그 43 PASS를 Stage 2/3 매출·활성화·
retention·margin·CAC의 LGTM 근거로 세지 않는다. 현재 source tree의
`tests/integration/acceptance/budget_and_kill_switch.rs:3-17`도 실제 DB/worker/
provider effect가 아니라 환경변수 존재 여부만 precondition으로 검사한다.

종료 조건:

1. source freeze 후 MANIFEST/checksum/tree digest를 먼저 재생성한다.
2. 동일 digest로 OPS-004의 positive populated trace와 모든 unknown/blocking
   케이스를 재생성한다.
3. budget/kill-switch acceptance가 실제 PostgreSQL row, reservation/
   settlement, provider-call count, audit/outbox를 검증하도록 바꾼 뒤 반복 실행한다.

## 긍정 증거와 경계

- `services/public-api/src/service/public_funding.rs`와 `pub-023` trace는 무료
  공개 경계, 독립성, unknown disclosure를 잘 지킨다.
- paid Evidence Workspace/25 business metrics는 현재 authority ZIP의 Stage 1
  출시 사실이 아니다. branch의 `specs/product/business-model-contract.yaml`
  및 `business-model-addendum` 증거가 존재하더라도 새 authority revision과
  완전한 API/UI/runtime/회계 증거 없이 유료 모델이 이미 운영된다고 주장하면 안 된다.
- 위 blockers가 해결되고 동일 digest의 독립 재검토가 끝날 때까지 business
  verdict는 변경하지 않는다.

## Evidence digests

```text
services/control-api/src/service/query_business.rs a1642095f0071436366e38f62c50bb04696cbac78c53f7758cf3c169f942ba4d
packages/ui/src/view-models/ops-004.ts b28522117769357e2b2727cf8ca270f97fa31ef39548eab87a5fef316c4e51fa
services/public-api/src/service/public_funding.rs 903790acfd592d5eb31a8a97152f4ce852240bcb6e1f816847bcba2fa9b495c4
implementation-evidence/runtime-traces/ops-004.json 5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
implementation-evidence/runtime-traces/pub-023.json 5ed2a3103567e055f8f1f2dccb6d5723de6ff751089f86a58c995f4f22b7b9ff
tests/integration/acceptance/budget_and_kill_switch.rs b9fd89fab3cd697d483d118b379d2a828935f55734648878b3ce7d1c2ce34
```
