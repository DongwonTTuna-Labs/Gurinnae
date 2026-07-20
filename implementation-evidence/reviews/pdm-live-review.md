# PdM live implementation review — current worktree

검토일: 2026-07-20 UTC  
권위 ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`  
검토 범위: 현재 source tree, 현재 implementation-evidence, PostgreSQL journey receipts  
변경 범위: source는 수정하지 않았고 이 리뷰 문서만 작성했다.

## Verdict

```text
PDM_VERDICT: CHANGES_REQUIRED
```

현재 구현에는 많은 도메인/DB 함수와 정상·부정 branch receipt가 있으나, 핵심 사용자 여정의 기능 완결성과 운영 가능성을 현재 source/archive에 대해 입증할 수 없다. `LGTM`을 발행하지 않는다.

## Blocking findings

### PDM-LIVE-001 — 최종 source/evidence freeze가 깨져 있음 (P0)

실제 실행 결과:

- `sha256sum --check MANIFEST.sha256` → **25 computed checksums did NOT match**.
- `python3 scripts/authority_tree_digest.py` → `MANIFEST mismatch before tree digest: apps/review-console/src/lib/server/screen-load.ts`.
- Flow 01–07 receipt의 source digest는 `27300c584021ee4b5b4d27562490d50c2e5d630259f2e5c01c409b779a88e5cf`, Flow 08–10 및 PDM-003은 `65621dbb71edf24eb2d...bb53674`이다. 서로도, 현재 tree도 같은 snapshot이 아니다.

따라서 각 receipt의 `pass: true`는 현재 source의 durable outcome을 증명하지 않는다. PdM 관점에서도 담당자가 어느 코드/DB 계약을 실제로 운영 중인지 재현할 수 없다.

### PDM-LIVE-002 — J-12 상업 가치 여정의 화면/API 경로가 연결되지 않음 (P0)

권위 여정 계약은 J-12를 `OPS-004`의 current-health 답변 → `INT-002` remediation acknowledgement → signed qualification → CONFIGURED/DATA_READY → paid workflow 순서로 요구한다 (`specs/product/addendum-journey-contracts.yaml:57-59,1725-1853`). 그러나 현재 구현은 다음과 같이 불일치한다.

- `apps/review-console/src/routes/internal/operations/budgets/screen.ts`의 OPS-004는 `envelope/spend/forecast/limits/alerts/changes`만 제공하고 `business-health` typed section 또는 J-12 remediation action이 없다.
- `apps/review-console/src/routes/internal/my-work/screen.ts`의 INT-002에는 일반 task/approval/handoff action만 있으며 `route__j12__ack_commercial_remediation_v1`, qualification receipt 입력, retention-watch acknowledgement 배치가 없다.
- `services/control-api/src/service/query_dispatch.rs:103-104`는 `getBudgetOverview`를 기존 `budget_overview_query`로만 dispatch한다. 이 query (`services/control-api/src/service/query_business.rs:5-93`)는 예산·공급자·dailySeries·topCases를 반환하고, `ops.read_business_health_projection_v1`/`BusinessHealthV1`를 호출하지 않는다. DB migration에 함수가 존재하는 것만으로는 화면 사용자 여정이 완결되지 않는다.
- `packages/ui/src/generated-screen-projections.ts:5857-5920`는 OPS-004의 `envelope`와 `spend`를 `getBudgetOverview.$.envelope`/`$.spend`에서 읽도록 되어 있지만 현재 query payload에는 두 키가 없다. 즉 current-health를 한눈에 읽는 typed projection이 서버 응답과 맞지 않는다.

이 상태에서는 고객/운영자가 “지금 무엇이 막혔고 다음에 누구에게 무엇을 요청해야 하는가”를 J-12에서 물 흐르듯이 수행할 수 없다.

### PDM-LIVE-003 — 사업 퍼널·활성화·유지 지표가 실제 제품 경로에 노출되지 않음 (P0)

`implementation-evidence/business-model-metric-dictionary.md:9,100-112`는 25개 business metric과 41개 supplemental acceptance 행이 모두 `implementation_status: MISSING`이며 `REVIEW_REQUIRED`라고 명시한다. 같은 문서는 OPS-004가 `BusinessHealthV1`(funnel, paid MVW, retention, revenue, reconciliation, margin, CAC, SLA/support)를 제공해야 한다고 적지만, 현재 OPS-004 API/UI는 legacy BudgetOverview만 사용한다. 

따라서 activation 7일 목표, first paid MVW, day-29–56 retention, churn/at-risk, cost-to-value, billing reconciliation을 실제 조직/episode/as-of 근거로 보고 다음 조치를 선택할 수 없다. 페이지 조회·로그인·fixture receipt를 유료 가치로 오인하지 않는다는 원칙은 지켜지고 있지만, 그 반대편인 “strict paid outcome을 표시하고 다음 retention watch를 생성”하는 기능이 아직 닫히지 않았다.

### PDM-LIVE-004 — 인증된 data-backed 화면 여정 evidence가 없음 (P0)

현재 `implementation-evidence/runtime-traces`에는 94개 화면 trace가 있으나, 내부/응답/운영 화면 56개를 집계하면 모두 `ssrStatus: 200`, `errorSummary: true`, 모든 section `projectionState: BLOCKED`이다. 예: `runtime-traces/ops-004.json`, `int-002.json`, `cas-010.json`, `cas-011.json`. 이 trace는 unauthenticated 오류·focus UX만 증명하며, DB seed → Control API → Svelte SSR/DOM에서 실제 case, agent output, approval, budget, retention 데이터를 읽고 행동을 완료하는 positive path를 증명하지 않는다.

특히 CAS-010/011 positive authenticated trace, OPS-004 BusinessHealth positive trace, INT-002 owner acknowledgement/approval queue trace가 없으므로 “사용자가 원하는 정보를 즉시 인지하고 다음 행동을 수행한다”는 PdM acceptance를 판정할 수 없다. `runtime-journey-receipts/*.json`는 PostgreSQL 함수/receipt chain 증거이지 브라우저 화면 완료 증거가 아니다.

### PDM-LIVE-005 — 외부 acceptance 439 시나리오의 sealed 실행 증거가 없음 (P0)

`FINAL_BUILD_CONTRACT.md:21`은 271 base 시나리오를 포함한 439 effective acceptance를 요구하고, `Makefile:101-140`의 `run-acceptance-439`/`verify-execution-evidence`는 외부 `ACCEPTANCE_EVIDENCE_ROOT`와 commit/tree/archive/extraction receipt binding을 필수로 한다. 현재 worktree에는 그 sealed `run-index.json`/extraction bundle이 없고 `ACCEPTANCE_EVIDENCE_ROOT`도 설정돼 있지 않다. 정적 registry와 일부 DB journey receipt만으로 전체 사용자 여정·운영 회복을 통과했다고 셀 수 없다.

## Non-blocking positive observations

- `implementation-evidence/runtime-journey-receipts/flow-01..10-20260719.json`은 개별 정상/negative branch와 PostgreSQL 18.4/serializable receipt를 기록한다.
- `implementation-evidence/runtime-journey-receipts/pdm-003-observability-20260719.json`은 source/rule/capacity/incident row를 읽는 owner projection을 기록한다.
- `services/control-api/src/service/query_analysis_detail.rs`는 현재 hypotheses/counterEvidence/unknowns/investigationsPerformed/nextActions 배열을 view-model에 보존하는 코드가 있다. 다만 이를 실제 authenticated browser 데이터로 검증한 trace가 없어 의미 보존을 닫을 수 없다.

## Required closure before re-review

1. 구현을 freeze하고 MANIFEST/MANIFEST.sha256 및 authority tree digest를 마지막에 재생성한다.
2. 하나의 최종 source digest로 Flow 01–10/PDM-003, 439 acceptance, archive clean-extraction parity를 재생성한다.
3. `ops.read_business_health_projection_v1`를 Control API operation과 OPS-004 typed projection에 연결하고, J-12의 OPS-004→INT-002 remediation/qualification/retention actions를 기존 route에 명시적으로 배치한다.
4. 실제 PostgreSQL organization/qualification/data-ready/paid-outcome fixture가 아닌 production-shaped seed로 OPS-004, INT-002, CAS-010, CAS-011의 authenticated wide/medium/compact positive traces를 저장한다. 화면에서 current state, unknown reason, evidence digest, owner와 next action을 확인한다.
5. 41개 supplemental business scenarios와 full 439 acceptance를 `skip_policy: FORBIDDEN`으로 실행하고 sealed external evidence로 검증한다.

이 조건이 모두 충족되고 동일한 최종 digest에 대해 독립 PdM 재리뷰가 통과하기 전까지 `PDM_VERDICT: LGTM` 또는 `VERDICT: ARTIFACT_READY`를 발행할 수 없다.
