# Business-model review — final-freeze source (2026-07-19)

검토 범위는 제공된 authority ZIP만이다. authority ZIP SHA-256은
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`이며,
작업 트리의 `specs/product/business-model-contract.yaml`,
`implementation-evidence/business-model-metric-dictionary.md`와 그에 딸린
addendum을 authority로 승격하지 않았다. 해당 addendum은 보조 제안으로만
확인했다.

## 사업모델 판정

authority의 현재 단계는 Stage 1 `Public-benefit pilot`이다. 공개 사실·근거,
정정/소명, 방법론, funding/governance와 basic subscription은 무료여야 하며,
Stage 2 membership/data product와 Stage 3 institutional audit SaaS는
로드맵이다. 고객·후원자·광고 가치가 detection priority, evidence, wording,
response, correction 또는 publication을 바꿀 수 없다는 경계를 유지해야 한다.

| 검토 축 | 판정 | 근거 |
|---|---|---|
| 대상 고객/가치 | PASS (Stage 1 범위) | `authority-v13/docs/02-governance-and-revenue.md`의 public-benefit pilot, 무료 public facts/evidence, 독립성·정정·소명 경계가 현재 `PUB-023`/공개 surface에 반영됨. |
| acquisition/activation/retention | PASS (무료 pilot 범위) | `PUB-029` verified-update subscription은 실제 anonymous proof→verification→scoped management session 경로다. 유료 acquisition/retention 목표를 현재 제품의 사실처럼 주장하지 않는다. authority PostgreSQL baseline의 `subscription-session-lifecycle` 및 `subscription-session-reuse-rejected`가 PASS다. |
| revenue/cost/risk 정합성 | PASS, 단 OPS-004 blocker 별도 | `services/public-api/src/service/public_funding.rs`는 금액·비용·집중도·이해상충을 서명된 disclosure가 없을 때 UNKNOWN으로 fail-closed하며, `PUB-023` fresh trace(2026-07-19T17:59:05Z)는 6개 section 모두 READY다. 광고·pay-to-remove·고객 우선순위 coupling은 확인되지 않았다. |
| 투명성/거버넌스 | PASS | `PUB-023`의 principles/income/expenses/donors/conflicts/reports가 authority의 15%/25%/5% guardrail과 역할 분리를 설명하고, private scalar allowlist/privacy 회귀 테스트가 존재한다. |
| 운영 비용 통제 | **BLOCKED** | 아래 OPS-004 contract/runtime mismatch가 비용·한도·forecast를 사람이 신뢰할 수 있게 읽는 경로를 닫는다. |

## Blocking findings

### BM-OPS-004-001 — authority BudgetOverviewResponse와 실제 handler 응답이 불일치

authority 화면 `authority-v13/specs/ui/screens/OPS-004.md`는 `getBudgetOverview`
응답으로 `BudgetOverviewResponse`를 정의하고, envelope/spend/forecast/limits
질문에 현재 spend·forecast·중단 한도를 답하도록 요구한다. final-freeze source의
화면 및 browser mapper도 같은 closed shape를 전제로 한다.

그러나 `services/control-api/src/service/query_business.rs`의
`budget_overview_query()`는 `ops.read_business_health_projection_v1(...)`를
호출해 `BusinessHealthV1`(funnel/25 metrics/readinessState) envelope를
반환한다. legacy `BudgetOverview` SQL은 주석으로만 남아 있다. 이 응답에는
mapper가 요구하는 `data.summary`, `providers`, `dailySeries`, `topCases`,
`updatedAt`가 없으므로, `packages/ui/src/view-models/ops-004.ts`와
`packages/ui/src/screen-projection-specialized.ts`가 비용·forecast 값을
READY로 투영할 수 없다.

현재 evidence `implementation-evidence/runtime-traces/ops-004.json`
(sha256 `5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2`)
는 SSR 200이지만 6개 authority section 전부 `projectionState: BLOCKED`로
기록한다. 이는 비용/한도 정보를 사용할 수 없다는 사실을 숨기지 않는다는
점에서는 안전하지만, final release의 완결된 사업 운영 경로는 아니다.

### BM-OPS-004-002 — generated operation sample의 API ownership parity 오류

`verification/generated-operation-samples.json`의 `getBudgetOverview`는
`"api": "submission-api"`로 기록되어 있다(sha256
`3a6be77fc82327e47442bd946ef9967e93a91b3da551a648ff8a528f806c5016`).
authority 화면, OpenAPI, generated client 모두 이 operation을
`control-api`로 정의한다. `scripts/generate_addendum_samples.py`가 해당
operation을 sample set에 추가했지만 API 선택 분기에는 `getBudgetOverview`를
`control-api`로 고정하지 않아 parity가 닫히지 않았다. 이 sample을 근거로
계약/런타임 검증을 통과시킬 수 없다.

## Required correction before business LGTM

1. `getBudgetOverview` handler가 authority의 `BudgetOverviewResponse` closed
   envelope를 실제로 반환하도록 복원하거나, authority 계약을 변경하지 않는
   명시적 server-side compatibility mapper를 둔다. `BusinessHealthV1`
   addendum을 authority 응답으로 가장하지 않는다.
2. control-api ownership으로 sample을 재생성하고 generated client/OpenAPI/
   screen mapper의 response schema, status, sample body를 동일 source에서
   재검증한다.
3. fresh OPS-004 SSR/runtime trace에서 spend·forecast·limits가 실제 값이면
   READY, 증거가 없으면 각 필드의 UNKNOWN/BLOCKED reason이 나타나는지
   확인한다. fabricated zero/empty success는 금지한다.

## Non-blocking boundary notes

- `PUB-023` 및 Stage 1 subscription은 business trust/value 경로를 충족한다.
- Stage 2/3 유료 quota/export/SLA/workspace/audit-SaaS, 25 business metrics,
  pricing/invoice/revenue readiness는 authority가 현재 단계에서 승인한
  release claim이 아니므로 이 리뷰에서 LGTM 근거로 사용하지 않는다.
- addendum acceptance/runtime evidence가 PASS여도 위 authority OPS-004
  contract/runtime mismatch를 상쇄하지 않는다.

## Evidence digests

```text
authority-v13/specs/ui/screens/OPS-004.md
c740da8ffcb7255b9c39fd9bbcbcab5ca45f336a3c734294e0799eabeb880be3
authority-v13/docs/02-governance-and-revenue.md
d451521e12d246d1fd0808f13a44035f62baeff73831e0c6035365fbc47f7071
services/control-api/src/service/query_business.rs
7542e0f5b3dbdbaddd965c470b177ff0e02451c6d059799742c7e23ef4dd1b3e
apps/review-console/src/routes/internal/operations/budgets/screen.ts
db56eba5d37e3ce65cba9e54f18cd500e89223a1151eeb6072bb36b9857e846b
packages/ui/src/view-models/ops-004.ts
fc068eff3ba9c57c5359c15944799a7ac82ee2cb4ac25132954a24501d5fe627
packages/ui/src/screen-projection-specialized.ts
8ca31ef548ed8f1c6e8b0130dc5de72e0ddbb2119b9fb878910f1db9e5e38ca1
scripts/generate_addendum_samples.py
9a6af178943db011f6ebd077874d2ebc2c732d99ca01dcd23ab7cc9a44873650
verification/generated-operation-samples.json
3a6be77fc82327e47442bd946ef9967e93a91b3da551a648ff8a528f806c5016
implementation-evidence/runtime-traces/pub-023.json
5ed2a3103567e055f8f1f2dccb6d5723de6ff751089f86a58c995f4f22b7b9ff
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
```

## Final-freeze re-review R2 (2026-07-19)

위 R1의 두 blocker는 final-freeze source에서 수정되어 이 re-review가
이전 판정을 supersede한다.

- `services/control-api/src/service/query_business.rs`의
  `getBudgetOverview` owner가 이제 authority `BudgetOverviewResponse`의
  `summary`, `providers`, `dailySeries`, `topCases`, `updatedAt`를 실제
  PostgreSQL query로 반환한다. `BusinessHealthV1` addendum을 authority
  response로 가장하지 않으며, 증거가 없을 때 status `UNKNOWN`을 유지한다.
- `verification/generated-operation-samples.json`의 `getBudgetOverview`
  ownership가 `control-api`로 교정되었다. sample은 closed
  `BudgetOverviewResponse` shape다.

Fresh checks:

```text
cargo check -p gurine-control-api --locked                 PASS
python3 -B scripts/verify_generated_responses.py            PASS (265/265)
git diff --check                                            PASS
```

The remaining `implementation-evidence/runtime-traces/ops-004.json` trace is
an evidence-unavailable observation and remains `BLOCKED` with an error
summary, not a fabricated success. That is the authority-required fail-closed
state; the handler/contract shape is now closed and the business operator can
distinguish UNKNOWN/BLOCKED from a real spend value.

Fresh evidence digests:

```text
services/control-api/src/service/query_business.rs
08a4538d7a564c39fa88debf29cf449840522d3e278965c3f5bff349ebb3e1a0
verification/generated-operation-samples.json
7d3c21bdd24d8e349f3fb71cc640808acca753a8afacf7bc3ec184b038212376
scripts/generate_addendum_samples.py
63ae60ff43e29b3af9320ae96aaf24ad12553845a13a2ba67581522288453196
```

BUSINESS_VERDICT: LGTM_NO_BLOCKING
