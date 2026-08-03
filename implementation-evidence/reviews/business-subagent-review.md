# Business-model subagent review — current source

검토일: 2026-07-20  
검토 범위: 제공된 authority ZIP과 현재 worktree의 source/runtime evidence만 검토  
Authority ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

## Verdict

`BUSINESS_SUBAGENT_VERDICT: CHANGES_REQUIRED`

Authority의 현재 사업 단계는 `docs/02-governance-and-revenue.md`가 정의한
Stage 1 public-benefit pilot이다. 공개 사실·근거·정정·소명·방법론·기본 구독은
무료이고, 돈·후원자·고객의 영향이 탐지 우선순위나 공개 판단을 바꾸지 않아야
한다. 현재 funding surface는 서명된 disclosure가 없을 때 `UNKNOWN`을 반환하는
fail-closed 경계가 있어 이 원칙은 지켜진다. 그러나 운영비와 AI 비용을 실제
값/미확인으로 구분해 통제하고, 승인자가 위험·담당·기한·다음 중단 조치를
즉시 이해하는 경로가 아직 닫히지 않았다. 따라서 Stage 1의 가치·운영 가능성
주장을 `LGTM`으로 승격할 수 없다.

## Review matrix

| 축 | 현재 판정 | 근거 |
|---|---|---|
| 대상 고객·가치 전달 | Stage 1 범위 PASS | authority `docs/00-project-charter.md`, `docs/27-product-strategy-and-principles.md`의 시민/기자/연구자/소명 담당자 가치와 공개 근거·정정 경계가 source surface에 존재한다. |
| 획득·활성화·유지 | Stage 1 범위만 PASS | authority는 회원·데이터 상품·기관 SaaS를 Stage 2/3 로드맵으로 둔다. 현재 subscription은 공개 업데이트 알림 경로이며 유료 funnel/retention의 증거로 주장하면 안 된다. |
| 수익·편집 독립성 | 조건부 PASS | `services/public-api/src/service/public_funding.rs`는 후원·비용·집중도·이해상충 자료가 없을 때 UNKNOWN으로 닫는다. 금지된 pay-to-remove/priority coupling은 이 surface에서 확인되지 않는다. |
| 비용·예산·리스크 운영 | **BLOCKED** | 아래 BM-OPS-004, BM-COST-UNKNOWN, BM-APPROVAL findings가 열려 있어 비용·한도·승인 결정을 신뢰할 수 없다. |
| 현재 evidence binding | **BLOCKED** | `business-model-20260719.json`은 43개 addendum 시나리오 PASS라고 명시하지만 authority monetization 승인으로 취급하지 않는다. flow/runtime receipt 세대와 현재 source digest parity가 다시 검증돼야 한다. |

## Blocking findings

### BM-OPS-004 — 비용 화면이 사업 의사결정에 필요한 의미 슬롯을 채우지 못함 (P0)

authority `OPS-004`는 현재 spend/forecast, 소모 workload, 한도 초과 시 중단,
forecast confidence/assumption, soft/hard/fallback limit, threshold alert,
approver/reason 변경 이력을 즉시 답해야 한다. 현재 API는
`BudgetOverview`의 summary/providers/dailySeries/topCases만 조회한다.
`packages/ui/src/screen-projection-specialized.ts:146-176`은 forecast를 단일
최근 시계열 점으로, alerts를 `EXCEEDED ? 1 : 0`으로, changes를 updatedAt/version으로
투영한다. 이는 forecast confidence/assumption, 실제 threshold, 변경 approver/reason,
중단/fallback을 제공하지 않는다. 데이터가 없으면 해당 필드를 `UNKNOWN`/`BLOCKED`와
owner/retry 경로로 표시해야 하며, 0건/최근 한 점을 실제 forecast/alert 부재로
해석하게 해서는 안 된다. authority closed schema를 확장할 경우에는 별도 승인된
계약 변경이 필요하다.

추가로 `services/control-api/src/service/query_business.rs:12-16`은 budget limit와
cost event가 없을 때 currency/limit/used/monthly 값을 문자열 `KRW`/`0`으로
채운다. status는 UNKNOWN이어도 카드의 확인된 필드로 0원이 노출될 수 있다.
원장 부재는 null + typed unknown reason으로 유지하고, 값이 유효한 원장에 있을
때만 숫자를 표시해야 한다.

필수 종료 증거:

1. clean PostgreSQL에서 real spend/forecast/limit/alert/change rows와 원장 부재
   케이스를 각각 실행한다.
2. 여섯 OPS-004 section이 실제 값 또는 명시적 UNKNOWN/BLOCKED reason을 보이는
   SSR/browser trace를 저장한다.
3. response schema, generated client, mapper, screen projection이 같은
   source snapshot에 묶였음을 재검증한다.

### BM-COST-UNKNOWN — AI 비용 원장 누락/비정상이 0원·가용 예산으로 축약됨 (P0)

`services/control-api/src/service/query_analysis_vm.rs:61-85`의 `cost_micros`는
누락·파싱 실패를 0으로 반환한다. `:275-295`는 maxCost 문자열만 있으면
`budget.state = AVAILABLE`로 만들고, malformed/NULL actual cost를 settled 0으로
합산한다. CAS-011도 같은 변환을 사용한다. 이는 비용 원장이 없거나 provider
receipt/reconciliation이 닫히지 않은 상태를 무료/정상 잔여 예산으로 보이게 해,
AI 호출 승인·kill-switch·가격/비용 판단을 왜곡한다.

필수 수정/검증:

- 금액 파서는 `Option<Result<...>>` 같은 typed 상태로 바꾸고 NULL/overflow/형식
  불일치를 UNKNOWN/BLOCKED로 보존한다.
- reserved/settled/remaining은 실제 reservation·settlement receipt와
  provider cost reconciliation에서만 계산한다. 숫자 0은 실제 0원 원장이
  있을 때만 허용한다.
- CAS-010/CAS-011 화면에서 cost ledger 상태, unknown reason, provider receipt,
  reconciliation freshness를 함께 확인할 수 있게 하고 clean runtime evidence를
  남긴다.

### BM-APPROVAL — 승인 큐가 위험·담당·필터 사실을 상수로 덮어씀 (P0)

AI가 제안하고 사람이 승인하는 가치 경로에서 승인자는 왜 이 행동을 승인하는지,
누가 맡았는지, 언제까지인지, 어떤 quorum/SoD가 필요한지를 즉시 알아야 한다.
현재 `services/control-api/src/service/query_addendum_queue.rs:137-180`은
`riskClass`를 항상 `MEDIUM`, `assignment`를 항상 null, required slot을
`actions.review`로 만들고, `listActionApprovalQueue`의 applied filters를 빈
상수로 반환한다. 이는 실제 owner/risk/due/filter 결과가 없는데도 정상 승인
대기열처럼 보이게 한다. authority의 human accountability 및 고위험 행동
승인 원칙에 맞게 DB owner projection의 typed facts를 그대로 사용하거나,
누락 시 각 필드를 UNKNOWN/BLOCKED로 표시해야 한다. query filter/cursor/sort는
실제 적용값과 결과에 바인딩하고, 승인 전 외부 channel 효과가 실행되지 않는
receipt/reconciliation까지 clean PostgreSQL에서 입증해야 한다.

## Non-blocking observations

- `services/public-api/src/service/public_funding.rs`의 UNKNOWN disclosure는
  비용·후원자·이해상충을 0 또는 정상으로 포장하지 않아 독립성 원칙에 부합한다.
- `implementation-evidence/runtime-journey-receipts/business-model-20260719.json`
  자체가 addendum evidence이며 “authority-v13 monetization approval이 아님”을
  명시한다. 이 PASS를 이용해 유료 acquisition/retention/revenue readiness를
  주장하지 않는다.
- Stage 2 membership/data product와 Stage 3 institutional audit SaaS는
  authority 로드맵이다. 현재 release는 무료 public-benefit pilot로 명확히
  라벨링하고, 유료 경로를 노출하려면 별도 authority/ADR·계약·billing·rights
  증거를 먼저 승인해야 한다.

## Evidence digests

```text
authority-v13/docs/02-governance-and-revenue.md
d451521e12d246d1fd0808f13a44035f62baeff73831e0c6035365fbc47f7071
authority-v13/specs/ui/screens/OPS-004.md
c740da8ffcb7255b9c39fd9bbcbcab5ca45f336a3c734294e0799eabeb880be3
services/control-api/src/service/query_business.rs
92640bbea0f672030f3981b390b05c7053efd3d993ffb5a1e9190abc0c73f2ab
packages/ui/src/view-models/ops-004.ts
fc068eff3ba9c57c5359c1594479a7ac82ee2cb4ac25132954a24501d5fe627
packages/ui/src/screen-projection-specialized.ts
da534a45974b25b6fa255e4d50e1aef4fdbd5e926c2699350c6d730746683b0a
services/control-api/src/service/query_analysis_vm.rs
3b95787d83a035cfc88059c2afd9a99c72dcc37798ce5fac83cc31c6d1c64f99
services/control-api/src/service/query_addendum_queue.rs
6702ff4fbee648b586bd3a3a4d1e8102d03b67e1b079c8784a65c3f4a41a241f
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
implementation-evidence/runtime-journey-receipts/business-model-20260719.json
34fce1f6e016213960753172ff8d9b5996916e214fc4ba860e51f224965570f1
```
