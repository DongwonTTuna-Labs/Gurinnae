# Designer implementation review — current source tree

DESIGN_VERDICT: CHANGES_REQUIRED

ROLE: PRODUCT_DESIGN / ACCESSIBILITY_RESPONSIVE
REVIEWED_AT_UTC: 2026-07-20
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
REVIEWED_COMMIT: `5a3431b02c2132fe24276a6ed21db28dc69db099`
SOURCE_DIGEST_AT_REVIEW: `195c8cb3242bad2c7f35e3965bc072eab6fd6bf426427aa09874e92f3a8a0d75`

## 범위와 확인 방법

권위 문서의 순서에 따라 `CODEX_HANDOFF.md`, `CODEX_START_HERE.md`,
`AGENTS.md`, `FINAL_BUILD_CONTRACT.md`, `VERIFY.md`를 확인한 뒤 `DESIGN.md`,
`docs/45-final-design-direction.md`, `docs/46-screen-composition-standard.md`,
`docs/37-accessibility-inclusive-design.md`, `docs/38-responsive-and-device-strategy.md`,
94-screen `design-screen-closure.yaml`, 공통 Svelte renderer와 현재 E2E/evidence를
읽기 전용으로 대조했다. 이 기록 작성 외 소스는 수정하지 않았다.

실행 증거:

- `bun run --filter @gurine/ui check` — 0 errors / 0 warnings
- `bun run --filter @gurine/ui test` — 5 files / 38 tests PASS
- `bun run --filter @gurine/ui build` — PASS
- `bunx playwright test tests/e2e/acceptance/accessibility-responsive.spec.ts --grep ACCESSIBILITY_RESPONSIVE` — 8/8 PASS
- `sha256sum --check MANIFEST.sha256` — FAIL (`services/ingest-worker/src/ingest_jobs.rs` mismatch)
- 현재 `DESIGN.md`와 `design-screen-closure.yaml`의 status는 `REVIEW_REQUIRED`이며
  `DESIGN.md` §15.1에는 UX/AI/DATA/QA를 포함한 open closure ledger가 남아 있다.

## P0 blockers

### D-CURRENT-001 — source/evidence/manifest freeze가 성립하지 않음

현재 `MANIFEST.sha256`가 `services/ingest-worker/src/ingest_jobs.rs`와 불일치하고,
source digest가 `195c8cb3…a0d75`인 dirty tree다. 따라서 현재 UI와 visual/runtime
receipt, screenshot, CAS evidence가 최종 source에 귀속됐다고 말할 수 없다. 특히
`DESIGN.md`/screen closure가 `REVIEW_REQUIRED`이고 open ledger가 비어 있지 않아
freeze validator의 FINAL 조건도 충족하지 않는다.

필수 조치: 구현 변경을 멈춘 하나의 clean source snapshot에서 MANIFEST/sidecar,
94개 route/state 및 대표 CAS·response·approval의 data-backed visual/AX/runtime
receipt를 다시 생성하고, source digest·archive parity·clean extraction을 같은
세대로 재검증한다. 그 전까지 디자인 verdict는 release에 사용할 수 없다.

## P1 blockers

### D-CURRENT-002 — UnifiedSearch와 execution receipt가 raw runtime DTO를 읽음

`packages/ui/src/components/sections/UnifiedSearch.svelte:10-13`은
`runtime.data.searchResults ?? runtime.data.results`를 순회해 결과 수를 만들고,
`StructuredContentSection.svelte:34-35`와
`ExecutionReceiptPanel.svelte:20`은 `runtime.data.getActionExecutionReceipt`를
직접 읽는다. 이는 `AGENTS.md`/`DESIGN.md §5.2`의 서버-owned typed projection만
브라우저에 노출하고 DTO·필드명 추측을 금지하는 invariant를 우회한다. projection이
누락되거나 DTO shape가 바뀌면 사용자는 권위 없는 빈/오래된 결과를 정상 상태로
읽을 수 있으며, 검색 결과의 record-level destination·freshness·pagination도
화면에서 닫히지 않는다.

필수 조치: 검색 결과와 execution receipt를 `ScreenRuntimeProjection`의
화면별 discriminated VM/envelope로 BFF가 준비하고, 컴포넌트는 그 envelope만
소비하게 한다. projection이 없으면 scope·원인·owner·retry/reauth가 있는
UNKNOWN/BLOCKED를 렌더하고, raw DTO 주입 negative test를 추가한다.

### D-CURRENT-003 — 23개 collection/ledger 화면이 generic key-value table로 축약됨

`packages/ui/src/components/sections/DataCollection.svelte:1-8`은 23개 화면/section을
동일한 `OperationData mode="table"`로 위임한다. `OperationData.svelte:40-60`은
허용된 필드의 2열 표만 만들고 record-level link/destination, cursor pagination,
result count/change announcement, filter scope/freshness, row error/recovery를
표현하지 않는다. `PUB-003`의 `results`/`pagination`, 내부 cases/signals,
source runs/schema drift, response attachments/receipt 같은 핵심 동선에서
사용자가 원하는 항목을 즉시 열고 다음 행동을 선택할 수 없으므로
`DESIGN.md §5.2`, `docs/46-screen-composition-standard.md`의 screen-specific
typed VM·next-action 계약과 인지부하 목표를 충족하지 못한다.

필수 조치: 각 collection archetype에 typed row VM(라벨·상태·revision/freshness·
destination·expected version/digest), URL 복구 가능한 filter/pagination, empty/
filtered-empty/partial/stale/error/offline copy와 row-level keyboard action을
구현한다. generic `OperationData`는 도메인 목록의 유일한 renderer가 될 수 없다.

### D-CURRENT-004 — unknown/error 상태가 범위·owner·재검토 시점·복구 정보를 잃음

`packages/ui/src/components/OperationData.svelte:11-35`의 UNKNOWN/STALE/ERROR/
PARTIAL 문구와 `AuthorityRecordSection.svelte:26-35`의 error/partial 문구는
내부 상태를 안전한 단어로 바꾸지만 affected scope, 담당 owner, 기준 시각/다음
재검토, 저장·초안 보존 여부와 정확한 retry/reauth/offline/conflict action을
제공하지 않는다. `DESIGN.md §5.2`는 오류가 affected scope·saved/draft state·
focus·field link를 설명하고 §6은 상태별 deterministic recovery를 요구한다.
현재 focus는 요약으로 이동하지만 사용자가 무엇을 어떻게 복구해야 하는지는
알 수 없다.

필수 조치: 화면별 state envelope에 `scope`, `owner`, `asOf/nextReviewAt`,
`preservedInput`, `recoveryAction`을 포함하고 상태·필드별 copy와 focus target을
구현한다. 94-screen state matrix에서 각 required state를 실제 DOM/keyboard/
screen-reader receipt로 검증한다.

### D-CURRENT-005 — 접근성 acceptance 8개가 전부 PUB-004만 실행함

`tests/e2e/acceptance/support.ts:11-25`의 `screenByJourney`가
`ACCESSIBILITY_RESPONSIVE`를 항상 `PUB-004`로 매핑한다. 따라서 현재 8/8 PASS는
사건 상세 한 화면의 heading/landmark/overflow/모바일 drawer만 증명하며,
RSP-002..006, REV-002/003, CAS-010/011, OPS-006, AUTH-004 및 나머지 89개
화면의 keyboard, table header, form error, focus restoration, live region,
forced-colors, 200/400% zoom, stale/offline/conflict 상태를 증명하지 않는다.
`FINAL_BUILD_CONTRACT.md`와 `DESIGN.md §6/§14`의 94-screen acceptance 및
evidence-bound closure를 충족하지 못한다.

필수 조치: 최소 대표 public/CAS/response/review/ops/auth 화면을 실제
non-empty·error·stale·offline·conflict 데이터로 compact/medium/wide와 200/400%
zoom, keyboard-only, reduced-motion, forced-colors에서 실행하고, 각 receipt에
screen ID·state·source digest를 묶는다. 선언/route count smoke를 접근성 증거로
대체하지 않는다.

### D-CURRENT-006 — 빈 typed projection이 성공 상태에서 빈 section으로 남음

`packages/ui/src/components/sections/AuthorityRecordSection.svelte:22-35`는
projection이 존재하지만 `fields.length === 0`이고 `projection.state`가
`UNKNOWN`인 경우를 별도로 처리하지 않는다. `runtime.state === "success"`이며
선언 필드는 있는 응답이면 첫 두 분기와 loading/error/forbidden/blocked/empty
분기가 모두 건너뛰어져 section heading·purpose 아래에 아무 설명도 남지 않는다.
이는 계약 누락을 empty success처럼 보이게 하며 `DESIGN.md §5.2`의
"missing binding is a contract error, never an empty success"와 ten-second
uncertainty/recovery 요구를 위반한다.

필수 조치: `projection.state === "UNKNOWN"` 또는 declared field가 있는데
known field가 0인 경우를 명시해 scope·원인·owner와 retry/reauth 안내가 있는
BLOCKED/UNKNOWN 상태를 렌더하고, success + empty-envelope negative test를
94개 화면 state matrix에 추가한다.

## Retest of prior designer findings

- `D-FREEZE-001` / `D-LIVE-001`: **OPEN** — MANIFEST mismatch와 dirty source digest가 현재도 관찰됨.
- `D-FREEZE-002` / `D-LIVE-002`: **CLOSED_CURRENT_TRUTH** — `AuthorityRecordSection`은 projection 부재 시 raw DTO 대신 BLOCKED 문구를 렌더한다.
- `D-FREEZE-003` / `D-LIVE-004`: **OPEN** — `OperationData`와 authority-record 상태 copy에 내부 path는 제거됐지만 scope/owner/review/recovery metadata가 없다.
- `D-FREEZE-004`: **CLOSED_CURRENT_TRUTH** — CAS specialized projection은 allowlisted scalar/row fields와 typed visual/table payload를 사용하며 `JSON.stringify`/임의 key 표시를 하지 않는다.
- `D-FREEZE-005`: **PARTIAL / OPEN** — `local-actions.ts`의 raw recursive DTO scan은 제거됐지만 `UnifiedSearch`와 execution receipt가 아직 raw `runtime.data`를 읽는다.
- `D-FREEZE-006` / `D-FREEZE-007`: **CLOSED_CURRENT_TRUTH for field richness** — CAS run/input/citation/decision rows와 compact `data-label` table이 현재 source에 존재한다. 다만 data-backed source-digest-bound browser evidence가 freeze되어야 최종 closure다.
- `D-CURRENT-006`: **OPEN** — success + empty `AuthorityRecordSection` still has no visible unknown/recovery branch.

## Positive observations

- `ScreenPage.svelte`는 public/response/internal/auth surface별 h1, main, status/live, section focus target과 sticky-header scroll margin을 일관되게 제공한다.
- `PublicHeader`, `ApprovalDecisionDialog`, `ScreenActions`, `StructuredJsonField`에 skip link, 44px target, dialog focus return, field error association, reduced-motion/forced-colors 규칙이 있다.
- `AgentAnalysisProjection`은 CAS metric의 narrative/table 대안과 CAS-011 provenance table에 `data-label`을 제공한다.
- UI typecheck/unit/build 및 현재 8개 acceptance는 재현 가능하게 PASS했다. 이는 위 P0/P1을 닫는 증거로 확대 해석하지 않는다.

## Verdict

현재 공통 layout과 대표 CAS projection은 이전 세대보다 개선됐지만, raw DTO side
doors, generic collection renderer, 불충분한 state recovery copy, 한 화면에만
매핑된 accessibility evidence, 그리고 source/evidence freeze 불일치가 남아
있다. 위 blockers를 root 수정하고 동일 source digest로 전체 evidence를 재생성한
뒤 독립 재리뷰가 필요하다.

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```
