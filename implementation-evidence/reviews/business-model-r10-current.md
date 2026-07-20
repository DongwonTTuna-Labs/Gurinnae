# Business-model independent review R10 — current source

검토 일시: 2026-07-20  
권위 ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

이 문서는 최신 current source-tree만 다시 읽어 독립적으로 작성한 business-model
final-freeze 검토다. 이전 business-model verdict는 재사용하지 않았다. 기준은
Stage 1 public-benefit pilot의 무료 공개 사실·근거, verified-update subscription,
독립성 및 fail-closed 비용/승인 운영이다.

## 판정

`BUSINESS_VERDICT: CHANGES_REQUIRED`

무료 공개 가치와 후원 독립성 경계는 유지된다. 그러나 비용·한도·승인 위험을
사람이 신뢰하고 다음 행동을 고를 수 있게 하는 운영 경로가 아직 닫히지 않았다.

## Blocking findings

### BM-R10-OPS004 — 빈 데이터와 의미 슬롯이 READY로 통과

`packages/ui/src/view-models/ops-004.ts`의 `complete`는 summary의 모든 문자열,
updatedAt 및 세 배열의 존재만 검사한다. 배열이 비어 있어도 `projectionState`
가 `READY`가 된다(동일 동작을 `packages/ui/src/screen-contract.test.ts`가
현재 기대값으로 고정한다). `packages/ui/src/screen-projection-specialized.ts`는
forecast를 최신 시계열 한 점으로만, alerts를 `EXCEEDED ? 1 : 0`으로, changes를
updatedAt/version으로만 표시한다. 권위 OPS-004가 요구하는 forecast
confidence/assumption, alert threshold, changes approver/reason이 없는데도
0건·READY가 표시되어 예산/kill-switch 의사결정을 오도할 수 있다. 증거가 없으면
필드별 `UNKNOWN/BLOCKED`와 이유를 내보내거나 실제 typed owner projection을
연결해야 한다.

현재 `implementation-evidence/runtime-traces/ops-004.json`은
`observedAt=2026-07-19T15:35:51.541Z`의 6개 section BLOCKED trace일 뿐, 최신
수정본의 실제 BudgetOverview 또는 각 UNKNOWN 이유를 입증하는 fresh trace가
아니다.

### BM-R10-APPROVAL — 승인 큐가 위험·담당·쿼리 의미를 잃음

`services/control-api/src/service/query_addendum_queue.rs`의
`normalize_action_queue_items`는 `assignment: null`, `riskClass: "MEDIUM"`,
`requiredSlots: ["actions.review"]`, 빈 satisfied 슬롯과 `complete: false`를
모든 항목에 주입한다. `addendum_queue_query`는 listActionApprovalQueue의
actionKind/proposalState/assignmentState/dueBefore/cursor/limit/sort를 받지
않고 appliedFilters를 상수로 반환한다. DB 함수
`ops.read_action_queue_v1()`(migration 0030)는 proposal/version/due/digest만
제공하므로 현재 응답은 실제 governance risk, assignment, quorum 사실의
표현이 아니다. 승인자가 위험·담당자·기한·quorum을 신뢰하려면 owner projection
조인과 query/filter 적용을 구현하고, 증거가 없을 때는 명시적인 blocked/unknown
경로를 사용해야 한다.

### BM-R10-AI-COST — 비정상 비용이 0원/SETTLED/AVAILABLE로 변환

`services/control-api/src/service/query_analysis_vm.rs`의 `cost_micros`는
누락·malformed 문자열을 0으로 파싱한다. CAS-010은 문자열이 존재하기만 하면
`has_limit=true`로 두고 0 값의 `AVAILABLE` budget을 만든다. CAS-011
`build_view_model`도 빈 문자열 또는 malformed `actualCost`를 문자열 존재로
판정해 `SETTLED`와 0 settled/remaining을 표시한다. `packages/ui/src/
screen-projection-specialized.ts`의 CAS-010/CAS-011 반환은 `blocked: false`
로 고정되어 비용 원장 부재가 section UNKNOWN/BLOCKED로 승격되지 않는다.
유효한 원장 숫자만 노출하고, 누락·비정상·재조정 필요는 값 null + 원인 +
재검토 경로로 유지해야 한다.

### BM-R10-EVIDENCE — fresh runtime 증거 부족

`implementation-evidence/runtime-traces/cas-010.json`과 `cas-011.json`도
2026-07-19의 all-BLOCKED trace다. fail-closed 자체는 안전하지만, latest
source의 데이터-backed cost UNKNOWN/BLOCKED 및 analysis/provenance renderer가
실제 브라우저에서 도달하는지 입증하지 못한다. 수정 후에는 동일 source digest로
fresh SSR/browser trace와 cost-malformed/missing fixtures를 추가해야 한다.

## Positive evidence

- `services/public-api/src/service/public_funding.rs`는 signed evidence 부재 시
  funding/cost를 UNKNOWN으로 두고 후원자 concentration 및 editorial firewall을
  유지한다.
- CAS analysis VM은 현재 `ScreenSection`의 `AgentAnalysisProjection`으로
  visualization table/narrative 및 CAS-011 provenance graph를 전달하는 closed
  mapper 경로가 존재한다. 다만 위 비용 상태 gate와 fresh runtime 증명이 남아 있다.
- `cargo check -p gurine-control-api --locked` PASS (2026-07-20),
  `bun run --filter '@gurine/ui' test` 38/38 PASS. 이 테스트들은 malformed cost,
  OPS-004 빈 배열 READY, approval query filter semantics를 검증하지 않으므로
  위 blocking findings를 해소하지 않는다.

## Current source digests

```text
services/control-api/src/service/query_analysis_vm.rs 3b95787d83a035cfc88059c2afd9a99c72dcc37798ce5fac83cc31c6d1c64f99
services/control-api/src/service/query_analysis_detail.rs a7a937f7c59042412593e7030b87db924d6a3d8d2dd7e242f7fb9846b64a78f3
services/control-api/src/service/query_addendum_queue.rs 6702ff4fbee648b586bd3a3a4d1e8102d03b67e1b079c8784a65c3f4a41a241f
packages/ui/src/view-models/ops-004.ts fc068eff3ba9c57c5359c15944799a7ac82ee2cb4ac25132954a24501d5fe627
packages/ui/src/view-models/cas-010.ts 133e40728a01796e89076f0f02d91987a229d3531d0d6ec5e275526cb308b7ad
packages/ui/src/view-models/cas-011.ts 16742ee85ca46933e5e39924330bd4cfa640e06da47082b3bddb7cba4cc5dced
packages/ui/src/screen-projection-specialized.ts da534a45974b25b6fa255e4d50e1aef4fdbd5e926c2699350c6d730746683b0a
authority-v13/specs/ui/screens/OPS-004.md c740da8ffcb7255b9c39fd9bbcbcab5ca45f336a3c734294e0799eabeb880be3
specs/product/addendum-resource-error-contracts.yaml e01390da1defbab158d3ee15efffc4a4db88982c73a1244cea0db1cfb32ca41f
```

`BUSINESS_VERDICT: CHANGES_REQUIRED`
