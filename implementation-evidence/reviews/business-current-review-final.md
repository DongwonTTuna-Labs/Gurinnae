# Business-model review — current source (fresh final review, 2026-07-20)

검토 기준은 첨부된 v13 authority ZIP SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`뿐이다.
이전 Gurinnae 버전·이전 리뷰의 verdict를 재사용하지 않았고, 소스는 수정하지
않았다. 현재 working tree, authority OPS-004/운영비 문서, PostgreSQL
reservation/settlement owner 함수, 현재 runtime receipts를 독립 대조했다.

## 판정

`BUSINESS_VERDICT: CHANGES_REQUIRED`

Stage 1 public-benefit pilot의 고객 가치와 편집 독립성 경계는 지켜진다. 공개
사실·근거·정정·소명과 기본 업데이트 구독은 무료이고, 후원/고객이 조사 우선순위나
공개 판단을 살 수 없다는 원칙이 `public_funding.rs`와 PUB-023 경로에 있다.
`FLOW-09`도 무료 구독의 create→verify→scoped session→read와 부정 검증을
PostgreSQL 18.4에서 증명한다. 그러나 사업 운영자가 비용·예산·AI 비용·forecast를
실제 원장과 구분하여 판단하고 비용 보고서를 재현 가능한 산출물로 받는 경로가
아직 닫히지 않았다. 따라서 전체 business LGTM은 불가하다.

## 검토 매트릭스

| 축 | 판정 | 현재 근거 |
|---|---|---|
| 대상 고객·가치 전달 | Stage 1 범위 PASS | authority `docs/27-product-strategy-and-principles.md`의 시민·기자·연구자 JTBD와 무료 evidence/정정 원칙, public funding surface가 연결된다. |
| 획득·활성화·유지 | 무료 pilot 범위 PASS | PUB-029 subscription과 current `FLOW-09`의 검증·관리 세션 경로는 확인된다. Stage 2 유료 quota/workspace/SLA, CAC·유료 retention은 authority의 현재 출시 사실로 주장하지 않는다. |
| 수익·편집 독립성 | 조건부 PASS (fail-closed) | signed funding disclosure가 없으면 `public_funding.rs`가 금액·비용·집중도·이해상충을 UNKNOWN으로 유지하며 pay-to-remove/priority coupling이 보이지 않는다. |
| OPS-004 비용·예산 운영 | **BLOCKED** | query가 reservation/settlement ledger·freshness·soft/hard/fallback·threshold alert·approver/reason을 읽지 않고, 관측 부재/혼합 통화를 문자열 0으로 만든다. |
| AI 비용·승인 판단 | **BLOCKED** | CAS-010/011은 owner `budgetLedger`를 일부 읽지만 OPS-004와 동일한 사업 비용 snapshot/원장·provider usage reconciliation의 positive/negative matrix가 없다. |
| 비용 report export | **BLOCKED** | `cost_export_query`가 `agent_runs` 단순 합계 후 id/status/version metadata만 돌려 binary body·checksum·period/groupBy row를 만들지 않는다. |
| 최신 실행 증거 | **BLOCKED** | authenticated CAS receipts는 2026-07-20에 fresh지만 CAS-010이 PARTIAL이고 OPS-004 trace는 2026-07-19 all-BLOCKED이며 source digest도 없다. |

## Blocking findings

### BM-FINAL-OPS004 — 예산 observation과 사업 metric을 false-green으로 만들 수 있음 (P0)

`services/control-api/src/service/query_business.rs`(현재 digest
`392f668f3ce8a29471e300e31137d3be3a2e1fe8fc80e91bb2502de66c215faa`)는
`ops.budget_limits`와 `ops.cost_events`만 읽는다. budget/cost row가 없거나
통화가 섞여도 `dailyLimit`, `dailyUsed`, `monthlyLimit`, `monthlyUsed`를
`"0"`으로, currency를 `"UNKNOWN"`/일부 경로의 `KRW`로 채운다. status에
`UNKNOWN_*` 문자열은 있지만 값과 상태가 한 화면에서 분리되지 않아 비용 0과
관측 불능을 같은 숫자로 읽게 된다. `dailySeries`/`topCases`도 단일 통화만
필터하면서 `max(currency)`를 선택한다.

authority `docs/11-operations-and-cost.md`는 job 시작 전 reservation, 실제
settlement, cap 도달 시 `PAUSED_POLICY`·human queue, override의 reason/amount/
expiry/approver를 요구한다. DB에는 immutable `ops.budget_reservations`와
`ops.budget_reservation_ledger_entries`, `ops.read_agent_run_budget_projection_v1`
owner function이 존재하지만 OPS-004 query는 이 원장을 조회하지 않는다. 또한
`ops.read_business_health_projection_v1`가 산출하는 qualification/activation/
retention/revenue/margin/CAC metric은 SQL 결과에 `businessHealth`로 넣어도
`response_materialize.rs`의 authority closed `BudgetOverview` schema에서
제거된다. 현재 screen registry는 authority와 맞는 6개 section
(envelope/spend/forecast/limits/alerts/changes)으로 복귀했으므로 그 addendum을
화면에 섞어 해결한 것으로 볼 수도 없다. 사업 health를 보여주려면 별도 승인된
closed operation/projection이 필요하다.

**필수 종료 조건**

1. observation·limit·currency·period·freshness가 없으면 숫자 0이 아닌 nullable
   값과 typed `UNKNOWN/BLOCKED` reason/owner action을 반환한다. mixed currency는
   합산하지 않는다.
2. reservation/settlement/reconciliation ledger와 pause/override receipt를
   같은 as-of snapshot으로 연결한다. authority closed response 밖의 business
   health는 별도 승인된 closed operation으로 분리하거나 UI에서 제거한다.
3. clean PostgreSQL 18.4에서 populated, no-observation, mixed-currency, stale,
   reservation-only, settled, reconciliation-required, over-cap 케이스를 모두
   실행하고 wide/compact SSR trace를 동일 source digest로 저장한다.

### BM-FINAL-EXPORT — 비용 export가 재현 가능한 원장 산출물이 아님 (P0)

`services/control-api/src/service/query_business.rs::cost_export_query`는
`ops.agent_runs.actual_cost/max_cost`를 날짜 조건으로 합산한 JSON을 만든 뒤
`{"id","status","version"}`만 반환한다(동일 current source digest).
`groupBy`와 `format`은 검증에만 쓰이고 provider/model/case/day별 row,
reservation/settlement/provider-usage membership, exact `[from,to)` window,
empty/unknown/partial/mixed-currency/correction 상태가 결과에 보존되지 않는다.
authority `screen-data-contracts.yaml`는 `exportCostReport`의 required `binary`
field를 명시하고, 화면 integration dependency는 filename/media type/byte
length/checksum/rights/revision metadata를 binary와 함께 요구한다. 반면
authority OpenAPI의 `BinaryDownload` schema는 id/status/version만 선언하는
내부 충돌이 있으므로 `implementation-evidence/spec-conflicts.md`에 해결을
기록하고 fail-closed로 닫아야 한다. 현재 구현은 양쪽 어느 쪽에도 충분하지 않다.

**필수 종료 조건**

1. immutable reservation/settlement/provider usage와 correction head를 기준으로
   exact period/groupBy의 deterministic CSV/JSON bytes를 materialize한다.
2. response/download 경계에 bytes, filename, media type, length, checksum,
   rights/revision metadata와 audit/export receipt를 연결하고 OpenAPI/generated
   client를 동일 source에서 재생성한다.
3. empty와 unknown/blocked를 구분하는 export witness 및 corrected/mixed-currency
   케이스를 clean DB에서 실행한다.

### BM-FINAL-CAS — AI 비용 원장 positive/negative business witness 부족 (P1)

`query_analysis_vm.rs`(digest `7fa06aa0eff6fb5240546f3f86fb40b77b997aab58fe93733a6b5c3cf687aa5f`)
및 `query_analysis_detail.rs`(digest
`109c60fe1bf9fa01315e81030893fefdfeb3d0d5a412de78202b4deb55ae0b81`)는
`listCaseAgentRuns`가 반환한 `budgetLedger`의 reservation/settled/exposure/
available을 typed cost로 투영하고 malformed/negative/overflow 값은 null로
유지하는 개선이 있다. CAS-011 authenticated trace의 cost section이 READY인
것도 긍정적이다. 그러나 CAS-010 authenticated trace는 runs/filters/suggestions/
budget 모두 PARTIAL이며, 현재 receipt는 실제 provider usage·settlement row,
reconciliation hold·over-cap pause가 화면에서 함께 검증된 증거가 아니다. CAS
cost와 OPS-004 사업 비용도 동일 snapshot/digest로 묶이지 않는다.

**필수 종료 조건**

1. reservation-only, settled(provider usage+billed digest), released(no-bill),
   reconciliation-required, malformed/missing, over-cap/pause를 각각 seed하고
   DB row→Control response→SSR projection→다음 action을 검증한다.
2. CAS-010/011와 OPS-004가 동일 ledger facts와 as-of/currency semantics를
   사용하도록 연결하고 source/digest/receipt를 저장한다.

### BM-FINAL-EVIDENCE — 최신 source와 동일 digest의 OPS-004 witness 부재 (P0)

`implementation-evidence/runtime-traces/ops-004.json`(digest
`5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2`)는
`observedAt=2026-07-19T15:35:51Z`, SSR 200이지만 envelope/spend/forecast/limits/
alerts/changes 6개 section 모두 `BLOCKED`, `errorSummary=true`이고 source tree
digest가 없다. 이는 관측 불능을 숨기지 않는 fail-closed 관찰로는 유효하지만,
현재 source의 populated spend/forecast/limits와 unknown 케이스를 증명하지
않는다. 반면 `cas-010-authenticated.json`(2026-07-20, PARTIAL)과
`cas-011-authenticated.json`(2026-07-20, cost READY)은 인증 경로의 별도 증거이며
OPS-004 positive evidence를 대체하지 않는다.

현재 `FLOW-08/09/10` 및 PDM-003 receipt는 sourceTreeDigest
`888a6d75253412dd881e23c38c4323b86e345d983070a7942a8203c1152b7723`를 사용하고
PostgreSQL 18.4의 고위험 action·구독·kill-switch를 증명한다. 그러나 그 receipt의
`business-model-20260719.json` 43 PASS는 문서가 명시하듯 implementation-addendum
증거이지 authority-v13 monetization approval이 아니다. Stage 2/3 revenue,
CAC, margin, paid retention을 현재 출시 사실로 주장할 수 없다.

**필수 종료 조건**

1. source freeze 후 MANIFEST/checksum/tree digest를 통과시킨다.
2. 동일 digest로 OPS-004 populated/empty/unknown/stale 및 export/ledger evidence를
   재생성하고, compact/wide authenticated trace와 response schema parity를
   보존한다.

## 긍정 및 경계

- `services/public-api/src/service/public_funding.rs`(digest
  `903790acfd592d5eb31a8a97152f4ce852240bcb6e1f816847bcba2fa9b495c4`)는 signed
  disclosure 부재를 UNKNOWN으로 처리하고 funding이 editorial priority를
  바꾸지 않도록 한다.
- `FLOW-09`는 anonymous proof→verification→scoped subscription session의
  실제 owner audit/outbox/readback과 invalid verification rejection을 보여줘
  Stage 1 무료 acquisition/activation/retention 경로의 범위 내 긍정 증거다.
- addendum BusinessHealth/paid-commercial surface는 현재 authority ZIP에 없는
  기능이다. 이를 구현하더라도 별도 authority 승인·billing/rights/isolation/
  receipt 증거 전에는 수익화 완료나 LGTM 근거로 쓰지 않는다.

## Fresh evidence digests

```text
authority-v13/docs/02-governance-and-revenue.md (authority-pinned)
authority-v13/docs/11-operations-and-cost.md (authority-pinned)
authority-v13/specs/ui/screens/OPS-004.md (authority-pinned)
services/control-api/src/service/query_business.rs
392f668f3ce8a29471e300e31137d3be3a2e1fe8fc80e91bb2502de66c215faa
services/control-api/src/service/response_materialize.rs
4526ccde20d1e5e9cadfc19378f20c3b276f017ab005e9c413d4ea51dbb777fd
apps/review-console/src/routes/internal/operations/budgets/screen.ts
943642530977e000cae12031e916d47010187a409bcda3bdbd07bf6b7fe22040
packages/ui/src/view-models/ops-004.ts
9f0cd1df16444d465bdfae262023af028074167a1298ffad132a19ac936dd5ad
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
implementation-evidence/runtime-traces/cas-010-authenticated.json
5a3183bf12acbe42d5a05cf72552dbf56a60bfdf3536bb6a34d2cbbb1683c235
implementation-evidence/runtime-traces/cas-011-authenticated.json
30eecc2e26ab46f525ba66ba4a075e4129c7ee742ab0ecb67ab8562d28303775
implementation-evidence/runtime-journey-receipts/flow-09-20260719.json
sourceTreeDigest=888a6d75253412dd881e23c38c4323b86e345d983070a7942a8203c1152b7723
```

`BUSINESS_VERDICT: CHANGES_REQUIRED`
