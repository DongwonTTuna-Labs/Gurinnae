# Business-model independent review R11 — current source

검토일: 2026-07-20  
권위 ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

이 문서는 현재 working tree를 다시 읽어 작성한 독립 business-model freeze
review다. 판단 기준은 첨부 v13 authority ZIP뿐이다. branch의 BusinessHealth·paid
commercial·action-approval addendum은 authority 승인으로 세지 않았으며, 구현이
그 기능을 노출하는 경우에는 authority 경계와 실제 wire/runtime 증거가 맞는지
보조적으로 대조했다.

## 판정

`BUSINESS_VERDICT: CHANGES_REQUIRED`

Stage 1 public-benefit pilot의 공개 사실·근거·정정·소명·기본 업데이트 구독은
무료이고 후원자·고객이 편집 우선순위나 공개 결정을 살 수 없다는 경계는 유지된다.
그러나 비용/예산 화면, 승인 대기열, AI 비용 원장이 실제 사업 의사결정에 쓸 수
있는 값인지 확인할 수 없고 최신 runtime evidence도 없다.

## Review matrix

| 축 | 판정 | 근거 |
|---|---|---|
| 대상 고객·가치 전달 | Stage 1 범위 PASS | authority `docs/00-project-charter.md`, `docs/27-product-strategy-and-principles.md`의 시민·기자·연구자 가치와 공개 근거/정정 경계가 public surface에 있다. |
| 획득·활성화·유지 | Stage 1 범위 PASS | `PUB-029`는 검증 후 scoped subscription session으로 이어지는 무료 업데이트 알림이다. authority가 Stage 2/3 로드맵으로 둔 paid quota·workspace·audit SaaS를 현재 매출 성과로 주장하지 않는다. |
| 수익·편집 독립성 | PASS (fail-closed) | `services/public-api/src/service/public_funding.rs`는 signed disclosure가 없으면 후원·비용·이해상충을 UNKNOWN으로 표시하고 pay-to-remove/priority coupling을 넣지 않는다. |
| 비용·예산 운영 | **BLOCKED** | 아래 BM-R11-OPS004 및 BM-R11-COST가 실제 spend/forecast/limit/settlement을 닫지 못한다. |
| 승인 기반 가치 경로 | **BLOCKED** | 아래 BM-R11-QUEUE는 addendum 기능을 authority 기능으로 오인할 수 있고, 필터·quorum·required facts를 실제로 보장하지 않는다. |
| 현재 evidence binding | **BLOCKED** | 관련 trace는 2026-07-19의 all-BLOCKED 관찰이며 현재 source digest/clean DB populated·malformed cases를 입증하지 않는다. |

## Blocking findings

### BM-R11-OPS004 — authority BudgetOverview closed contract와 server/UI projection 불일치

authority `authority-v13/specs/api/resource-schemas.yaml`의 `BudgetOverview`는
`summary`, `providers`, `dailySeries`, `topCases`, `updatedAt`만 허용하고
`additionalProperties: false`다. `BudgetOverviewResponse`도 `id/status/data/links`
closed envelope다.

현재 `services/control-api/src/service/query_business.rs:9-74`는 `data`에
authority에 없는 `limits`, `forecast`, `alerts`, `changes`를 추가한다. 같은 쿼리는
forecast를 단지 budget limit와 임의의 cost event가 존재한다는 이유로 `READY`,
confidence `MEDIUM`, 고정 한국어 assumption으로 만든다. 실제 forecast window,
계산 결과, freshness 또는 owner receipt가 없다. `ops.budget_limits`에는
authority baseline상 daily/monthly만 있고 soft/hard/fallback/approver 컬럼도 없다.

또한 currency가 섞인 원장에서는 summary 상태를 UNKNOWN으로 만들면서도
`dailySeries`와 `topCases`가 `max(currency)`를 선택해 합산 금액을 계속 노출한다.
`packages/ui/src/view-models/ops-004.ts:146-173`과
`packages/ui/src/screen-projection-specialized.ts:139-193`은 BLOCKED alert와 함께
이 known 숫자를 렌더링할 수 있다. 원장·forecast·limit evidence가 없거나
currency가 불일치하면 해당 값은 null + 구체적 reason + 재검토 경로여야 하며,
authority schema 밖 필드를 wire response에 몰래 추가해서는 안 된다.

`changes`도 최신 `updated_by`를 곧바로 `approver`로 투영하고 audit reason이
없으면 `BUDGET_LIMIT_UPDATE`를 삽입한다. 이는 승인 사실·사유를 증명하지 않는다.

더 직접적인 runtime 결과는 included module
`services/control-api/src/service/response_materialize.rs:42-109`
의 closed `materialize`가 `BudgetOverview` schema의 다섯 property만 복사한다는
점이다(`x-gurine-preserve-authority-projection`도 이 schema에는 없다). 따라서
위에서 SQL로 만든 네 추가 필드는 실제 HTTP 응답에서 제거되고, 현재 UI mapper가
읽는 forecast/limits/alerts/changes는 도달하지 않는다. 7월 19일 OPS-004 trace의
여섯 section BLOCKED가 이 경로와 일치한다.

**필수 종료 조건**

1. authority `BudgetOverviewResponse`와 byte/JSON-schema가 일치하는 server
   response를 유지하고, 여섯 OPS-004 section에 필요한 추가 의미가 별도 승인된
   closed projection이 아니라면 UNKNOWN/BLOCKED로 표현한다.
2. spend는 budget reservation/ledger settlement와 currency·window를 묶고,
   forecast confidence/assumption, soft/hard/fallback limit, alert threshold,
   approver/reason을 실제 persisted facts에서 읽는다. hard cap 도달 시 pause
   경로도 확인한다.
3. populated, empty, mixed-currency, stale/reconciliation-required 케이스를
   clean PostgreSQL 18.4에서 각각 실행하고 fresh SSR/browser trace를 source
   digest와 함께 남긴다.

### BM-R11-QUEUE — 승인 큐의 결과는 실제 query/quorum 의미를 보장하지 않음

`listActionApprovalQueue`는 authority ZIP에 없는 branch addendum operation이다.
따라서 현재 구현을 authority business approval로 주장할 수 없으며, 노출한다면
addendum 계약을 명시적으로 분리하고 실제 persisted facts로 닫아야 한다.

현재 `services/control-api/src/service/query_addendum_queue.rs:1-30,138-208`은
owner function에서 전체 큐를 먼저 읽은 뒤 애플리케이션 메모리에서만
`actionKind`, `proposalState`, `assignmentState`, `dueBefore`, `sort`를 걸러낸다.
따라서 persisted query predicate/authorization scope와 cursor가 같은 snapshot에
묶이지 않고, cursor는 서명·source digest 없는 숫자 offset으로 해석된다.
`appliedFilters`에는 `cursor`와 `limit`까지 넣는데 현재 closed
`ActionApprovalQueueFiltersV1` schema에는 이 두 필드가 없어 non-empty request의
응답이 schema-invalid다. dueBefore도 RFC3339 datetime 비교가 아니라 문자열
비교다. 결과가 필터·페이지 경계와 일치한다고 운영자가 재현할 수 없다.

정규화는 persisted value가 없을 때 `DRAFT`/`TASK`/version `1`/zero SHA를
삽입하고, `riskClass`를 `UNKNOWN`으로 만들 수 있다. addendum schema의
`riskClass`는 LOW/MEDIUM/HIGH/CRITICAL closed enum이고 `dueAt`는 non-null
datetime이다. `quorum.complete`는 `blockingSlots` 배열이 비어 있는지만 검사해
required slot과 counted current decision의 정확한 일대일 충족, distinct actor,
recusal/generation/approvalDigest를 증명하지 않는다. 이 값으로 승인자가
위험·담당·기한·quorum을 판단하게 하면 잘못된 승인/지연이 발생한다.

**필수 종료 조건**

1. authority surface와 addendum surface를 별도 registry·evidence로 표시한다.
2. persisted owner/assignment/quorum facts를 exact query predicates와 cursor,
   limit, sort에 묶고, 누락·VACANT·재조정 상태는 UNKNOWN/BLOCKED로 보낸다.
3. 실제 승인 전후 PostgreSQL row, immutable decision receipt, audit/outbox,
   execution/communication receipt를 포함한 fresh runtime probe를 저장한다.

### BM-R11-COST — CAS 비용이 reservation/settlement 원장에 묶이지 않음

authority `docs/11-operations-and-cost.md`는 job 시작 전 budget reservation,
실제 비용 settlement, cap 도달 시 pause와 명시적 override를 요구한다.

현재 `services/control-api/src/service/query_analysis_vm.rs:61-82,273-305`는
`ops.agent_runs.max_cost`/`actual_cost` 문자열을 합산한다. `cost_micros`는 소수
7자리 이상이나 두 개 이상의 `.`를 조용히 자르고, 음수 값도 허용한다. CAS-010은
한 run이라도 유효한 maxCost가 있으면 malformed/missing run을 합계에서 제외한 채
`AVAILABLE`로 만들 수 있고, `reservedMicrosKrw`를 `limit - settled`(잔여)와
동일하게 기록한다. 이는 reservation이 아니다.

CAS-011 `services/control-api/src/service/query_analysis_detail.rs:146-186`도
`actualCost` 문자열이 파싱되면 provider receipt, reservation state, settlement
ledger가 없어도 `SETTLED`다. malformed/missing 값만
`RECONCILIATION_REQUIRED`가 되며, 실제 `ops.budget_reservations`와
`ops.budget_reservation_ledger_entries`의 상태를 읽지 않는다. UI
`packages/ui/src/screen-projection-specialized.ts:37-123`는 이 상태를 직접
비용 숫자로 투영한다.

**필수 종료 조건**

1. 금액 파서는 전체 canonical numeric 문자열을 검증하고 negative/overflow/
   malformed/mixed currency를 UNKNOWN/BLOCKED로 보존한다.
2. CAS-010/011은 reservation, settlement/reconciliation receipt, provider
   usage/billed cost digest에서만 limit/reserved/settled/remaining을 계산한다.
   숫자 0은 실제 zero ledger fact일 때만 허용한다.
3. missing, malformed, reservation-only, settled, reconciliation-required,
   over-cap fixtures를 clean PostgreSQL에서 실행하고 browser projection trace로
   상태·reason·다음 행동을 확인한다.

### BM-R11-EVIDENCE — 최신 구현을 증명하는 fresh runtime witness가 없음

현재 파일 `implementation-evidence/runtime-traces/ops-004.json`,
`cas-010.json`, `cas-011.json`은 각각 `observedAt`가 2026-07-19 15:35Z이고
모든 section이 `projectionState: BLOCKED`, `errorSummary: true`다. 이는
fail-closed 한 관찰 하나를 보여줄 뿐 최신 source가 populated cost/forecast,
malformed cost, approval facts를 정확히 표시한다는 증거가 아니다.

`implementation-evidence/runtime-journey-receipts/business-model-20260719.json`
의 43개 PASS는 branch addendum acceptance이며 문서 자체가
“authority-v13 monetization approval이 아님”을 명시한다. 이를 authority
business LGTM 또는 fresh UI/runtime 근거로 사용할 수 없다.

## Positive evidence

- `services/public-api/src/service/public_funding.rs`는 서명된 disclosure가
  없을 때 후원·비용·이해상충을 UNKNOWN으로 유지하고, Stage 1 공개 사실과
  기본 구독을 유료 우선순위와 연결하지 않는다.
- 현재 response/schema 및 UI checks가 통과하더라도, authority-only closed
  schema와 ledger semantics를 검증하지 않는 한 위 blocker를 상쇄하지 않는다.

## Evidence digests

```text
authority-v13/specs/api/resource-schemas.yaml
(authority tree; ZIP sha pinned above)
authority-v13/specs/ui/screens/OPS-004.md
(authority tree; ZIP sha pinned above)
authority-v13/docs/02-governance-and-revenue.md
(authority tree; ZIP sha pinned above)
services/control-api/src/service/query_business.rs
2f82f03637100c1ea8ecd8307dbb759340bff829a044564fd33731f699939deb
services/control-api/src/service/query_addendum_queue.rs
c3d14a0d70ac7b5357976a4d593fc49986fc8a5b9680576803880b37e5402657
services/control-api/src/service/query_analysis_vm.rs
e8240941f79d8cd058d8a7078b76ad1493538520436b35b8b2b92b04baf7bb54
services/control-api/src/service/query_analysis_detail.rs
6b69a753fe8abca0b1c3f7517054757a989d17156a6773c631093fd6ef3dd2ad
packages/ui/src/view-models/ops-004.ts
7de4ab4e20cc33fc3467e8eb5b1e112d99688c7e7b74cea8209e15958d194947
packages/ui/src/screen-projection-specialized.ts
0ed0389d69c583a206600175f1f1b89d87e300ba003a71fe4da200cd80e4cafd
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
implementation-evidence/runtime-traces/cas-010.json
03e2601a58ddae54f64aae1ac07c9ce2408f088113da5cdf3306ba325af3bbd9
implementation-evidence/runtime-traces/cas-011.json
7960b20f6808818001413381946f42df30f933d1d7cb8f874759e354a73f7a6d
```
