# Designer independent review — current source (fresh pass 2)

DESIGN_VERDICT: CHANGES_REQUIRED

ROLE: PRODUCT_DESIGN / INFORMATION_ARCHITECTURE / ACCESSIBILITY_RESPONSIVE
REVIEWED_AT_UTC: 2026-07-20
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
SOURCE_DIGEST_AT_REVIEW: `0531d63aa61534571269f1ea6caea61a6f5113a7aa95ecef403c1814f2639686`

## Evidence

현재 worktree와 v13 authority ZIP만 사용했다. 94-screen registry, projection
mapper, OPS-004 sections, 공통 Svelte renderer, responsive CSS와 acceptance
harness를 읽기 전용으로 확인했다.

- `bun run --filter @gurine/ui check` — PASS (0 errors / 0 warnings)
- `bun run --filter @gurine/ui test` — PASS (5 files / 38 tests)
- OPS-004 — 권위 순서의 6 sections(envelope, spend, forecast, limits, alerts,
  changes)와 `business-health` projection mapper를 확인
- `DataCollection` component — 24개 section에 여전히 공통 사용
- `ACCESSIBILITY_RESPONSIVE` 8개 — 모두 `PUB-004`로 매핑
- `sha256sum --check MANIFEST.sha256` — FAIL (23개 mismatch; 이번 source
  snapshot은 아직 evidence freeze 이전)

UI compile/test와 OPS-004 연결은 이번 pass에서 닫혔지만, 아래 디자인 blocker와
manifest freeze 실패 때문에 LGTM은 발행할 수 없다.

## Blocking findings

### D-FRESH2-001 (P0) — source/evidence freeze가 현재 digest에 귀속되지 않음

현재 source digest는 `0531d63a…39686`인데 `sha256sum --check MANIFEST.sha256`가
23개 mismatch를 보고한다. 따라서 94-screen visual/AX/runtime receipt가 현재
source에 묶였다고 증명할 수 없다. 구현 변경을 멈춘 뒤 MANIFEST, 94-route/state
receipts, 대표 visual/AX evidence, clean archive parity를 같은 digest로
재생성해야 한다.

### D-FRESH2-002 (P1) — 24개 collection이 generic 2열 table

`packages/ui/src/components/sections/DataCollection.svelte`는 모든 collection을
`OperationData mode="table"`로 위임한다. PUB-003, PUB-011, CAS-001/003/006/008,
SRC-003/005/006, OPS-001/002/006, ADM-001 등 24개 section에 row identity,
status/as-of/revision/digest, 서버 승인 destination, cursor/page/count 변화,
row-level keyboard action, filtered-empty/partial/stale/offline recovery가
없다. 검색·사건·운영 동선의 object→state→evidence→next-action이 즉시 이어지지
않는다. collection archetype별 typed row VM/renderer와 상태·페이지·복구
metadata를 compact/medium/wide DOM/AX로 검증해야 한다.

### D-FRESH2-003 (P1) — UNKNOWN projection이 정상 field 목록으로 오인됨

`AuthorityRecordSection.svelte`는 `projection.fields.length > 0`이면 모든 field를
먼저 렌더한다. 계약 필드는 projection 부재에도 항상 존재하므로
`state=UNKNOWN`·`known=false` 응답이 각 값의 “확인 필요”만 보여주고 scope,
owner, as-of/next-review, preserved input 및 retry/reauth/offline/conflict
복구 정보를 표시하지 않는다. `SemanticSection`과 `StatusAndRevisionHeader`에도
같은 generic unknown 표현이 남아 있다. known 값이 없거나 section state가
UNKNOWN/BLOCKED/PARTIAL/STALE이면 typed state envelope와 복구 action을
우선 표시해야 한다.

### D-FRESH2-004 (P1) — 동적 navigation이 서버 destination을 우회함

`packages/ui/src/local-actions.ts`의 `contextualTarget`/`fallbackTargets`와
`ScreenPage.svelte`의 `caseTaskLinks`가 pathname/screen id를 조합해 CAS/SRC/
RULE/OPS 링크를 만든다. `runtime.destinations`가 없는 응답에서도 target
identity, expected version/digest, allowed state binding 없이 이동해 stale/
wrong-case 목적지를 만들 수 있다. 동적 action은 서버가 준비한 typed destination만
사용하고 누락 시 UNKNOWN/BLOCKED와 복구 안내로 닫아야 한다.

### D-FRESH2-005 (P1) — 94-screen 접근성 증거가 PUB-004에 편중

`tests/e2e/acceptance/support.ts`는 `ACCESSIBILITY_RESPONSIVE` 8개를 모두
`PUB-004`로 매핑한다. 공통 assertion은 CAS-010/011 compact provenance,
RSP field-error/draft, REV reason/reauth, OPS approval, AUTH/collection 상태·
focus/live-region을 증명하지 않는다. 각 distinct archetype 대표에 대해
non-empty/empty/partial/stale/offline/conflict/error를 320/360/390/768/1024/
1280@200%/1440/1920, keyboard-only, reduced-motion, forced-colors와 실제
DOM/AX로 검증하고 source digest-bound receipts를 남겨야 한다.

### D-FRESH2-006 (P1) — CAS 행 destination이 아직 링크가 아님

CAS projection은 runs/inputs/citations에 `href` field를 만들지만
`AgentAnalysisProjection`은 해당 section을 `OperationData` cards로 렌더한다.
`OperationData`는 scalar를 텍스트로만 출력하므로 실행·근거를 바로 여는
row-level link/button과 target binding이 없다. 서버 승인 destination을 typed
row VM으로 전달하고 `<a>`/button, stale/blocked copy 및 compact keyboard/
receipt 테스트를 제공해야 한다.

## Positive observations

- UI check/test는 현재 0 errors와 38/38 PASS로 projection mapper 회귀가 닫혔다.
- public/review/response loaders는 `data: {}`와 `projectFetchedData`를 사용해
  raw DTO hydration side-door를 줄였다.
- OPS-004 business-health와 CAS narrative/table 대안이 존재한다.
- 공통 CSS에 skip-link, focus-visible, reduced-motion, forced-colors와 compact
  `data-label` 처리가 있다.

## Verdict

UI compile/test와 OPS-004 6-section projection은 통과했지만 manifest/evidence
freeze, generic collection 정보구조, UNKNOWN 복구 UX, server destination
binding, 94-screen 접근성 증거, CAS row action이 닫히지 않았다. 위 blocker를
수정하고 동일 digest로 freeze·DOM/AX/visual evidence를 재검증한 뒤 독립
재리뷰가 필요하다.

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```
