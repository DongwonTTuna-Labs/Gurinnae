# Business-model review R9 — current source

검토 일시: 2026-07-19  
권위 ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

이 문서는 제공된 v13 권위 트리를 기준으로 현재 source의 고객 가치,
획득·활성화·유지, 수익·비용·리스크 정합성을 독립 재검토한 결과다.
이전 review verdict는 현재 source 변경 후 재사용하지 않았다.

## 판정

`BUSINESS_VERDICT: CHANGES_REQUIRED`

Stage 1 public-benefit pilot의 무료 공개 사실/근거, 독립성 guardrail,
funding disclosure 및 verified-update subscription 경계는 유지된다. 그러나
운영비·승인·AI 비용을 실제 값과 UNKNOWN으로 구분하지 못하는 경로가 있어,
사용자가 비용·위험·다음 행동을 신뢰성 있게 판단한다는 제품 가치가 닫히지
않는다.

## Blocking findings

### BM-R9-OPS-004 — 예산 화면의 의미 슬롯이 불완전함

`authority-v13/specs/ui/screens/OPS-004.md`는 forecast의 confidence/assumption,
alerts의 threshold, changes의 approver/reason을 요구한다. 현재
`packages/ui/src/view-models/ops-004.ts`는 provider/dailySeries/topCases가 빈
배열이어도 `READY`가 될 수 있고, `packages/ui/src/screen-projection-specialized.ts`는
forecast를 최근 시계열 1점, alerts를 `EXCEEDED ? 1 : 0`, changes를
`updatedAt`/version으로만 표시한다. 원장·forecast·변경 사유가 없는데도
READY 또는 0건으로 표시되면 비용·한도 의사결정이 오해된다. 해당 section은
실제 projection 또는 필드별 `UNKNOWN/BLOCKED` reason을 반환해야 한다.

### BM-R9-APPROVAL — 승인 큐의 위험·담당·필터 정보가 손실됨

`services/control-api/src/service/query_addendum_queue.rs`의
`normalize_action_queue_items`는 모든 proposal의 `riskClass`를 `MEDIUM`으로
고정하고 `assignment: null`, quorum 기본값을 생성한다. 또한
`listActionApprovalQueue`의 action/state/assignment/due/cursor/limit/sort
query를 읽지 않고 `appliedFilters`를 상수로 돌려준다. 승인자는 실제
governance risk/reasons, 담당자·기한·quorum을 즉시 알 수 없고, 필터 결과도
신뢰할 수 없다. addendum approval contract의 typed facts를 DB owner
projection에서 가져오거나 증거가 없을 때 명시적으로 `UNKNOWN/BLOCKED`로
표시해야 한다.

### BM-R9-AI-COST — AI 비용 부재가 무료/가용으로 오표시됨

`services/control-api/src/service/query_analysis_vm.rs`의 `cost_micros`는
누락·비정상 금액을 0으로 반환한다. CAS-010의 budget은 limit/reserved/
settled/remaining을 모두 0, state `AVAILABLE`로 고정하고 CAS-011도 비용
부재 시 0/NONE을 생성한다. 비용 원장이 없다는 사실을 0원·가용 예산으로
표시하는 것은 수익/비용·kill-switch 판단을 왜곡한다. 값이 없으면
`UNKNOWN`/`BLOCKED`와 원인·재검토 경로를 유지하고, 유효한 원장 값만
시각화해야 한다.

### BM-R9-AI-UX — 분석 결과·provenance가 사용자 화면에 도달하지 않음

독립 디자인 재검토(`product-design-final-freeze-r5-cas-v2.md`)에서
`analysis-vm.cas-010.v2`/`cas-011.v2`가 실제 `ScreenSection` 렌더 경로에
연결되지 않고, CAS-011 mapper가 `data.analysisVm`를 잘못 풀어 화면에서는
visualization/provenance가 `known:false`가 되는 것을 확인했다. 따라서
사용자가 무엇이 있었고 어떤 근거·인용·검증을 거쳤는지 한눈에 확인하는
핵심 가치와 AI→사람 승인 경로가 닫히지 않는다. 서버 envelope·OpenAPI·typed
mapper·section renderer를 같은 closed path로 연결하고 data-backed browser
trace에서 metric narrative/table과 provenance row를 확인해야 한다.

## Non-blocking 확인

- `services/public-api/src/service/public_funding.rs`는 Stage 1 독립성,
  후원자 concentration guardrail(15/25/5%), 비용·수익 disclosure의
  signed evidence 부재 시 UNKNOWN을 유지한다.
- Telegram/WhatsApp/LINE/SMS/Kakao typed adapter, consent/suppression,
  provider revision, idempotency 및 callback/poll receipt 경계는 존재하며,
  승인 전 외부 효과를 실행하지 않는 구조다. 실제 provider receipt와
  reconciliation은 별도 runtime evidence로 다시 닫아야 한다.
- 현재 `query_analysis_vm.rs`는 `node(NodeInput)` 호출 불일치로 전체 Rust
  build가 실패하므로, 이 리뷰는 compile-success/LGTM 근거가 아니다.

## Source digests

```text
services/control-api/src/service/query_business.rs
92640bbea0f672030f3981b390b05c7053efd3d993ffb5a1e9190abc0c73f2ab
services/control-api/src/service/query_addendum_queue.rs
928786725a7ea751544a426ad0b23d76f4f0179df252686c5b9289517cdc0eb7
services/control-api/src/service/query_analysis_vm.rs
38b678ecab3f60f732fbe8c06ddfe7f4011ac32358c66b607c86392991c1b097
packages/ui/src/view-models/ops-004.ts
fc068eff3ba9c57c5359c15944799a7ac82ee2cb4ac25132954a24501d5fe627
packages/ui/src/screen-projection-specialized.ts
01275f46667f2a720fcde8ac786241b06aa1520715418f9d09a280782de1fb76
authority-v13/specs/ui/screens/OPS-004.md
c740da8ffcb7255b9c39fd9bbcbcab5ca45f336a3c734294e0799eabeb880be3
specs/product/addendum-resource-error-contracts.yaml
e01390da1defbab158d3ee15efffc4a4db88982c73a1244cea0db1cfb32ca41f
```
