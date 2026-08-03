# PdM 독립 재검토 R3 (authority-v13 only)

`PDM_VERDICT: CHANGES_REQUIRED`

## R4 update (2026-07-19)

PDM-R3-002 is resolved for the product-structure runtime gate. The test now
uses the real PostgreSQL probe (`live_acceptance_probe`) rather than readiness
environment strings, and `ops.acceptance_runtime_probe_v1` has an explicit
`AC-PRODUCT_STRUCTURE-*` branch. On a clean PostgreSQL 18.4-bookworm instance
with all 30 runtime migrations applied, `cargo test -p
gurine-acceptance-tests --test product_structure -- --nocapture` passed 8/8.
The captured probe rows show `action`, `domain`, `receipt`, `audit`, `outbox`,
`event`, and `destination` all true for every scenario; see
`implementation-evidence/runtime-journey-receipts/product-structure-20260719.json`.

PDM-R3-001 and PDM-R3-003 remain blocking: this evidence covers the product
structure owner probe only, not the ten authority flows' operation-specific
normal/failure branches or the live source/parser/SLO/incident/kill-switch
observability matrix. No environment-only or fixture-only result is counted.

`ROLE: PDM / CORE_JOURNEYS / OPERATIONS / MEASUREMENT`

`REVIEWED_AT_UTC: 2026-07-19`

## 검토 범위와 원칙

이 리뷰는 첨부 authority-v13 snapshot(`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`)만
규범으로 사용했다. 현재 작업 트리의 addendum, business-model, supplemental
자료와 이전 리뷰 verdict는 판정 근거에서 제외했다.

대조한 authority 입력은 다음과 같다.

- `authority-v13/specs/ui/screen-catalog.yaml`
- `authority-v13/specs/ui/screen-build-manifest.yaml`
- `authority-v13/specs/ui/screen-data-contracts.yaml`
- `authority-v13/specs/ui/flows/01..10-*.md`
- `authority-v13/specs/api/operation-contracts.yaml`
- `authority-v13/docs/11-operations-and-cost.md`
- `authority-v13/docs/13-observability-and-quality.md`

## 통과한 검증

- Authority 화면 집합과 현재 화면 catalog/build manifest/data contracts가 각각
  94개 ID 및 section set에서 일치했다.
- Authority operation contract의 212개 operation과 현재 base operation catalog가
  수량 및 ID에서 일치했다.
- Authority screen action의 operation binding 111개가 현재 closure의 action
  contract와 정확히 일치했다.
- `verification/postgres-runtime-baseline.json`의 PostgreSQL 18.4 baseline은
  24 migrations / 107 tables / 72 functions / 64 concurrency contracts에서
  `result: PASS`이다. 이는 DB baseline 증거이며 application journey의
  end-to-end receipt 증거와는 별개다.
- `python3 -B -m scripts.validation.design_journey_graph`: exit 0
- `python3 -B -m scripts.validation.design_journey_self_test`: exit 0
- `python3 -B -m scripts.validation.design_ui_journeys`: exit 0
- 94개 route-bound SSR/DOM trace가 존재하고 모두 `ssrStatus=200`, `screenId`가
  route contract와 일치한다.
- `python3 -B scripts/validation/design_freeze.py --mode lint`:
  `STRUCTURE_LINT: PASS`, `structure_problem_count: 0`.

이 결과는 정적 계약·화면 렌더 경로가 authority 집합과 맞는다는 뜻이지,
각 authority flow가 실제 mutation/receipt/audit/outbox/destination까지 완료됐다는
뜻은 아니다.

## Blocking findings

### PDM-R3-001 — 94개 trace가 durable journey outcome을 증명하지 않음

현재 runtime trace는 SSR 상태와 section DOM 관찰만 기록한다. 전체 section
projection 관찰은 `BLOCKED=318`, `EMPTY=156`, `ERROR=9`, `READY=8`,
`UNKNOWN=4`, `PARTIAL=1`이며, authority flow 01~10 각각에 대해 command 실행,
PostgreSQL transition, immutable receipt, audit/outbox, 목적지 projection을
연결한 성공 receipt가 없다. 94개 화면이 200을 반환하는 것은 authority의
30초 이해, 재현/인용, 소명 제출, 정정/철회, drift recovery, rule activation,
reauth high-impact action, subscription, incident/kill-switch 성공 조건을
검증하지 않는다.

필요한 증거: authority flow 01~10 각각에서 정상 branch 1개와 핵심 실패/복구
branch를 실제 runtime에서 실행하고, operation ID, input/expected version,
PostgreSQL transition, receipt digest, audit/outbox ID, destination readback,
observed timestamp를 source-tree digest와 함께 보존한다.

### PDM-R3-002 — authority product-structure runtime gate (RESOLVED R4)

이전 실행의 `runtime_ready` 실패는 더 이상 현재 판정이 아니다. 최신
`implementation-evidence/runtime-journey-receipts/product-structure-20260719.json`
은 authority SHA-256에 고정된 PostgreSQL 18.4-bookworm, 30 migrations,
SERIALIZABLE probe에서 `cargo test -p gurine-acceptance-tests --test
product_structure -- --nocapture` 8/8 PASS를 기록한다. 여덟 시나리오 모두
`action`, `domain`, `receipt`, `audit`, `outbox`, `event`, `destination`이
true이며, `ops.acceptance_runtime_probe_v1(text)`를 실제로 호출했다.

이 증거는 product-structure gate만 닫는다. authority flow 01~10 전체의
operation-specific branch와 운영 SLI/recovery 증거를 대신하지 않는다.

### PDM-R3-003 — 운영 가능성/관측성의 live proof 부재

authority `docs/11-operations-and-cost.md`와
`docs/13-observability-and-quality.md`가 요구하는 source/parser freshness,
operation/job/source/rule version correlation, SLO window, incident/kill-switch
recovery 및 public degraded notice를 현재 evidence가 실제 데이터로 증명하지
않는다. 현재 archive에는 화면 trace와 static/catalog checks는 있으나 해당
운영 이벤트의 live receipt/readback matrix가 없다.

필요한 증거: source freshness, parser quality, operation latency/error,
publication/correction, provider/budget, incident/kill-switch에 대한 SLI
window receipt와 runbook action/recovery receipt를 최소 한 번의 clean
runtime run에서 수집하고, 화면의 degraded/unknown 상태와 같은 correlation ID로
readback한다.

## 판정

정적 authority set equality와 94-screen rendering, product-structure runtime
gate는 통과했지만, 위 두 가지
P0/P1 항목이 남아 핵심 사용자 여정의 durable outcome·실제 runtime readiness·
운영 가능성을 입증하지 못한다. 따라서 본 독립 PdM 재검토는 `CHANGES_REQUIRED`이며
`LGTM` 또는 `ARTIFACT_READY`를 발행할 수 없다.
