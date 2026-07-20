# Business-model review — current source R2 (2026-07-20)

이 리뷰는 첨부된 v13 authority ZIP(sha256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`)과 현재
working tree만 대조한 독립 read-only 검토다. 이전 Gurinnae 버전이나 이전
리뷰의 판정은 근거로 사용하지 않았다. 소스는 수정하지 않았고 이 파일만
리뷰 산출물로 추가했다.

## 판정

`BUSINESS_VERDICT: CHANGES_REQUIRED`

authority가 승인한 출시 단계는 `docs/02-governance-and-revenue.md`의 Stage 1
public-benefit pilot이다. 시민·기자·연구자는 공개 사실·근거·방법론·정정·소명에
무료로 접근해야 하며, 고객·후원·광고·수익은 조사 우선순위나 공개 판단을 바꿀
수 없다. 현재 funding surface는 이 독립성 경계를 잘 지키지만, 사업 운영자가
실제 비용·예산·forecast·export를 신뢰해 비용과 runway를 판단하는 경로가
닫히지 않았다. 따라서 고객/가치/독립성만으로 전체 business LGTM을 줄 수 없다.

## 검토 매트릭스

| 축 | 판정 | 현재 근거 |
|---|---|---|
| 대상 고객·가치 전달 | Stage 1 범위 PASS | authority `docs/27-product-strategy-and-principles.md`의 시민·기자·조사자·소명 담당자 JTBD와 무료 evidence/정정 원칙이 public surface에 반영돼 있다. |
| 획득·활성화·유지 | Stage 1 범위 PASS, 유료 성과 주장 금지 | Stage 2 membership/data product와 Stage 3 audit SaaS는 로드맵이다. 현재 구독은 무료 verified-update 경로이며 매출·CAC·retention 증거로 주장하지 않는다. |
| 수익·편집 독립성 | 조건부 PASS (fail-closed) | `services/public-api/src/service/public_funding.rs`는 서명된 disclosure가 없을 때 income/expense/concentration/conflict를 `UNKNOWN`으로 유지하고 pay-to-remove·고객 우선순위 coupling을 노출하지 않는다. |
| 비용·예산 운영 | **BLOCKED** | OPS-004 응답이 관측 부재·혼합 통화에서 금액 문자열 `"0"`을 내보내고 reservation/settlement, forecast, limits, alerts, change receipt를 제공하지 않는다. |
| 비용 보고서 export | **BLOCKED** | authority operation contract는 `exportCostReport`의 `BinaryDownload`에 필수 `binary` field를 요구하지만 handler는 집계 JSON의 id/status/version만 반환한다. |
| 최신 실행 증거 | **BLOCKED** | `ops-004.json`은 2026-07-19 trace이며 6개 section이 모두 BLOCKED이고, 현재 source digest와 일치하는 populated/empty/unknown 비용 witness가 없다. |

## Blocking findings

### BM-BUDGET-002 — 관측 부재를 0으로 투영해 false-green 사업 판단 가능

현재 `services/control-api/src/service/query_business.rs:12-23`은 budget limit,
cost event가 없거나 통화가 섞인 경우에도 `dailyLimit`, `dailyUsed`,
`monthlyLimit`, `monthlyUsed`를 문자열 `"0"`으로 채운다. status에
`UNKNOWN_NO_BUDGET_LIMIT`, `UNKNOWN_NO_COST_OBSERVATION`,
`UNKNOWN_MIXED_*`가 붙지만, 운영 화면의 숫자와 unknown reason이 분리되지
않아 비용 0원과 비용 관측 불능을 즉시 구분할 수 없다. `dailySeries`와
`topCases`도 단일 통화 행만 남기고 `max(currency)`/빈 배열을 사용한다
(`query_business.rs:31-49`).

authority `docs/11-operations-and-cost.md:81-105`는 job 시작 전 budget
reservation, 실제 비용 settlement, cap 도달 시 `PAUSED_POLICY`와 human queue,
override의 reason/amount/expiry/approver를 요구한다. 현재 BudgetOverview
query는 reservation/settlement ledger, pause state, override receipt,
freshness를 읽지 않는다. 화면 mapper
`packages/ui/src/view-models/ops-004.ts:139-187`도 forecast/limits/alerts/
changes가 없으면 `FORECAST_OWNER_FACT_MISSING` 또는 BLOCKED로만 표시한다.

**종료 조건**

1. 관측·한도·통화·기간·freshness가 없으면 금액을 `0`이 아닌 nullable 값과
   구체적인 `UNKNOWN/BLOCKED` reason 및 owner action으로 반환한다.
2. reservation/settlement 및 `PAUSED_POLICY`/override receipt를 authority
   BudgetOverview의 server-only projection에 연결하고 forecast, soft/hard/
   fallback limit, threshold alert, change history를 닫힌 응답으로 제공한다.
3. clean PostgreSQL 18.4에서 populated, no-observation, mixed-currency,
   stale/reconciliation 케이스를 실행하고 compact/wide SSR trace를 같은
   source digest로 저장한다. 관측 불능을 fabricated `READY` 또는 `EMPTY`로
   낮추지 않는다.

### BM-EXPORT-002 — `exportCostReport`가 authority의 binary report 계약을 이행하지 않음

authority `specs/api/operation-contracts.yaml`의 `exportCostReport`는
`response_schema: BinaryDownload`와 `response_fields: binary (required)`를
정의한다(`authority-v13/specs/api/operation-contracts.yaml:8318-8370`).
현재 `services/control-api/src/service/query_business.rs:129-160`은
`ops.agent_runs.actual_cost/max_cost`를 기간으로 단순 합산한 뒤
`{"id","status","version"}`만 반환한다. `groupBy`는 검증에만 사용되고
provider/model/case/day별 report row, requested period, format, checksum,
content bytes 또는 audit/export receipt가 생성되지 않는다.

현재 `crates/api-contracts/src/control_api.rs`의 generated sample도
동일한 metadata-only shape를 고정한다. 이는 단일 handler 수정으로 닫히지
않으며 generated client/OpenAPI/HTTP download 경계를 같은 source에서
재생성해야 한다.

**종료 조건**

1. reservation/settlement/provider usage와 correction head를 기준으로
   exact `[from,to)` period와 `groupBy`의 deterministic CSV/JSON bytes를
   materialize한다.
2. response와 server-only download 경계에 bytes/media type/filename/length/
   checksum 및 rights/revision metadata를 연결하고, binary digest를 audit에
   남긴다.
3. empty, unknown, partial, mixed-currency, corrected row를 각각 실행해
   `EMPTY`와 `UNKNOWN/BLOCKED`를 구분한 export witness를 저장한다.

### BM-EVIDENCE-002 — 최신 source와 동일 digest의 business witness 부재

`implementation-evidence/runtime-traces/ops-004.json`은
`observedAt: 2026-07-19T15:35:51.541Z`이며 envelope/spend/forecast/limits/
alerts/changes 전부 `projectionState: BLOCKED`다. 이 trace는 현재 dirty
source tree의 `services/control-api/src/service/query_business.rs`
(`392f668f3ce8a29471e300e31137d3be3a2e1fe8fc80e91bb2502de66c215faa`)와
동일 digest의 실행 증거가 아니므로 최종 release evidence로 재사용할 수 없다.
현재 `business-model-20260719.json`도 자체적으로 implementation-addendum
evidence이며 authority-v13 monetization approval이 아니라고 명시한다. 43개
PASS를 Stage 2/3 매출·CAC·margin·retention의 승인 근거로 세지 않는다.

**종료 조건**

1. source freeze 후 MANIFEST/checksum/tree digest를 재생성한다.
2. 동일 digest로 OPS-004 populated 및 모든 unknown/blocking 비용 케이스를
   재생성하고, budget reservation/settlement/pause/override audit·outbox를
   검증한다.
3. business review가 현재 source/evidence bundle을 다시 받아 위 blocker를
   독립적으로 재검토한다.

## 비차단 경계

- `services/public-api/src/service/public_funding.rs`의 공개 funding 문구는
  Stage 1의 무료 공개·독립성·UNKNOWN 경계를 지켜 positive evidence다.
- addendum의 25 business metrics, pricing/invoice/revenue readiness,
  institutional workspace/audit-SaaS는 authority ZIP의 현재 출시 사실이
  아니므로 이 리뷰의 LGTM 근거가 아니다.
- 비용·예산 blocker가 해결되고 동일 digest의 fresh runtime witness가 생길
  때까지 verdict를 변경하지 않는다.

## Evidence digests

```text
authority-v13/docs/02-governance-and-revenue.md
d451521e12d246d1fd0808f13a44035f62baeff73831e0c6035365fbc47f7071
authority-v13/docs/11-operations-and-cost.md
c0a161f3bb0675f18dc2478bb22d86947282985f27cae284ebae60fb75473c8b
authority-v13/specs/api/operation-contracts.yaml
(authority-pinned file; exportCostReport lines 8318-8370)
authority-v13/specs/ui/screens/OPS-004.md
c740da8ffcb7255b9c39fd9bbcbcab5ca45f336a3c734294e0799eabeb880be3
services/control-api/src/service/query_business.rs
392f668f3ce8a29471e300e31137d3be3a2e1fe8fc80e91bb2502de66c215faa
packages/ui/src/view-models/ops-004.ts
9f0cd1df16444d465bdfae262023af028074167a1298ffad132a19ac936dd5ad
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
services/public-api/src/service/public_funding.rs
903790acfd592d5eb31a8a97152f4ce852240bcb6e1f816847bcba2fa9b495c4
```
