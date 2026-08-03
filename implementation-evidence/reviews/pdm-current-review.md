# PdM current-worktree review — 2026-07-20

권위 기준은 v13 ZIP SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`와
현재 source tree다. 구현 파일은 수정하지 않았고 이 문서만 추가했다.

## Verdict

```text
PDM_VERDICT: CHANGES_REQUIRED
```

현재 소스에는 실제 PostgreSQL owner routine, submission/ingest 흐름, 정상·부정
branch 구현이 존재한다. 그러나 핵심 사용자 여정의 제품 완결성과 운영 가능성을
현재 source/archive에 대해 입증할 수 없어 LGTM을 발행하지 않는다.

## Blocking findings

### PDM-CURRENT-001 — runtime receipt가 현재 source snapshot에 결속되지 않음 (P0)

`python3`로 `scripts/generate_pdm_flow_evidence.py::source_digest()`를 현재
tree에서 계산한 값은 `9021dfe5d158771ba23b9ba8a81e6cfc14390181338a1a4e0543bae90866c0ab`다.
반면 `implementation-evidence/runtime-journey-receipts/flow-01..10-20260719.json`
및 `pdm-003-observability-20260719.json`은 모두
`sourceTreeDigest=489a5449aae43b854bf80ea4f3c646a88f0d46f655ae16cd9c8944c70466a9db`를
기록한다. 모든 receipt가 `pass: true`여도 현재 실행 가능한 source의 durable
결과를 증명하지 못한다. source를 freeze한 뒤 동일 digest로 flow/PDM-003을
재생성하고 archive clean-extraction/member parity를 다시 확인해야 한다.

`sha256sum --check MANIFEST.sha256` 자체는 현재 `rc=0`으로 통과했지만,
MANIFEST 통과만으로 stale runtime receipt의 불일치가 해소되지는 않는다.

### PDM-CURRENT-002 — J-12 OPS-004 핵심 상업-health 답변이 구현에서 제거됨 (P0)

권위 화면 계약 `specs/ui/screens/OPS-004.md:23-36`은 above-the-fold 두 번째
section으로 `business-health`를 요구하고 qualification·activation·retention·
revenue·margin·SLA projection을 표시하도록 한다. 현재
`apps/review-console/src/routes/internal/operations/budgets/screen.ts`에는
해당 section이 없고, `services/control-api/src/service/query_business.rs`의
`business_health_query`는 `ops.read_business_health_projection_v1`가 아닌
예산·cost_events 기반 `BudgetOverview` JSON을 반환한다.

따라서 `OPS-004 → INT-002 remediation acknowledgement → qualification →
CONFIGURED/DATA_READY → paid value/retention`이라는 J-12 진입 답변과 다음
조치가 화면/API에서 끊긴다. `BusinessHealthPanel.svelte`와 DB owner function이
존재하는 것만으로는 경로 연결 증거가 아니다. 계약 section, typed response,
server load, authenticated browser positive trace를 하나의 receipt로 연결해야
한다.

### PDM-CURRENT-003 — 설계·사업 계약이 아직 release 승인 상태가 아님 (P0)

현재 `DESIGN.md:5`,
`implementation-evidence/design-domain-closure.yaml:3`,
`implementation-evidence/design-screen-closure.yaml:3`,
`specs/product/business-model-contract.yaml:5`가 모두 `REVIEW_REQUIRED`다.
이 상태는 핵심 여정·정보위계·사업 funnel의 독립 승인과 source freeze가 끝나지
않았음을 의미한다. `implementation-evidence/business-model-metric-dictionary.md`
또한 41개 supplemental business scenario와 runtime mapping이 아직
`MISSING/OPEN`이라고 명시한다. 제안 문서·DB 함수·unit test만으로 paid outcome,
activation, retention, billing reconciliation을 운영 상태로 승격할 수 없다.

### PDM-CURRENT-004 — 인증된 data-backed 화면 완료 증거가 없음 (P0)

현재 `implementation-evidence/runtime-traces/cas-010.json`, `cas-011.json`,
`ops-004.json`, `int-002.json`은 모두 `ssrStatus: 200`이지만 각 section의
`projectionState`가 `BLOCKED`이고 `errorSummary: true`인 unauthenticated
관찰이다. source→PostgreSQL seed→Control API→Svelte SSR/DOM에서 실제 case,
AI output, approval queue, business health를 읽고 한 가지 다음 행동을 완료한
wide/medium/compact positive trace가 없다. 따라서 “10초 안에 현재 상태·불확실성·
근거·다음 행동을 이해한다”는 PdM 기준을 판정할 수 없다.

### PDM-CURRENT-005 — acceptance 및 omnichannel 운영 증거가 sealed 상태가 아님 (P0/P1)

현재 환경에 `ACCEPTANCE_EVIDENCE_ROOT`, `ACCEPTANCE_RUN_ID`, source/archive
binding 또는 sealed `run-index.json`/extraction receipt가 없다. `Makefile`의
`run-acceptance-439`/`verify-execution-evidence`는 이 값들을 필수로 하고
누락 시 즉시 실패한다. 별도로
`implementation-evidence/runtime-journey-receipts/pdm-003-observability-20260719.json`
의 `measured.providerTurns`가 `0`이며
`implementation-evidence/provider-runtime-closure.md`가 provider adapter receipt,
callback/poll, reconciliation을 remaining cross-surface gate로 남긴다.
승인된 rendering→consent/opt-out→gateway→provider receipt→reconciliation→UI
readback을 통과한 synthetic provider-double receipt가 없으므로 메일·SMS·
Telegram·WhatsApp·LINE·KakaoTalk 경로의 운영 가능성을 주장할 수 없다.

## Positive checks (blocking gate를 대체하지 않음)

- `sha256sum --check MANIFEST.sha256`: PASS (현재 tree 기준).
- `bash scripts/test-ingest-runtime.sh`: PASS (6-connector/44-operation
  checkpoint-raw-outbox-object-store ingest runtime).
- `services/control-api/src/service/query_analysis_detail.rs`에는 hypotheses,
  counter-evidence, unknowns, investigations, next-actions typed projection
  로직이 존재한다. 다만 위 PDM-CURRENT-004의 authenticated data-backed trace가
  없어 기능 완료 증거로 승격할 수 없다.

## Required closure before re-review

1. source 변경을 멈추고 현재 source digest로 Flow 01–10/PDM-003과 data-backed
   CAS-010/011·OPS-004·INT-002 traces를 재생성한다.
2. OPS-004 business-health section과 `read_business_health_projection_v1`를
   typed API/view-model/SSR 경로에 연결하고 J-12 remediation/qualification/
   retention action을 owner receipt로 닫는다.
3. `DESIGN.md`와 모든 design/business top-level status를 독립 LGTM 후 FINAL로
   고정하고 41 supplemental business scenarios를 skip 없이 실제 실행한다.
4. omnichannel provider-double의 consent, callback/poll, immutable receipt,
   reconciliation 및 UI readback을 추가하고 439 acceptance external evidence
   root의 sealed run-index/extraction receipt를 생성한다.
5. 변경 없는 동일 final digest로 PdM 독립 재리뷰를 다시 요청한다.

