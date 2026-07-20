# Designer independent review — current source/evidence (r2)

DESIGN_VERDICT: CHANGES_REQUIRED

ROLE: PRODUCT_DESIGN / INFORMATION_ARCHITECTURE / ACCESSIBILITY_RESPONSIVE
REVIEWED_AT_UTC: 2026-07-20
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
REVIEWED_COMMIT: `5a3431b02c2132fe24276a6ed21db28dc69db099` (worktree dirty)
SOURCE_DIGEST_AT_REVIEW: `498f850877bb370b719047cf0ea53e898061dab5db24e4d4e88754dcbd51d3eb`

## Review boundary and evidence

이번 검토는 첨부된 v13 authority ZIP과 현재 source tree만 사용했다. 이전 Gurinnae
버전이나 별도 자료는 사용하지 않았다. `docs/DESIGN.md`,
`specs/ui/accessibility-responsive-contracts.yaml`, effective screen contracts,
94-screen generated registry, 공통 Svelte renderer, projection mapper 및 E2E
acceptance를 읽기 전용으로 대조했다.

실행한 검사:

- `bun run --filter '@gurine/ui' check` — 0 errors / 0 warnings
- `bun run --filter '@gurine/ui' test` — 5 files / 38 tests PASS
- `git diff --check` — PASS
- `make verify-authority`에서 authority snapshot ZIP hash PASS를 확인했으나,
  strict validator는 이 검토 중 다른 프로세스와 중복 실행되어 완료 receipt를
  확보하지 못했다.
- `sha256sum --check MANIFEST.sha256` — FAIL, 12개 mismatch
  (`implementation-evidence/runtime-journey-receipts/flow-01..10-20260719.json`,
  `pdm-003-observability-20260719.json`,
  `packages/api-client-control/src/generated/types.gen.ts`).

타입/단위 테스트 통과는 최종 source digest에 묶인 94-screen 시각·접근성
evidence 또는 실제 사용자 동선의 정보 완결성을 증명하지 않는다.

## Blocking findings

### D-R2-001 (P0) — source/evidence freeze와 authority closure가 아직 성립하지 않음

현재 worktree가 dirty이고 `implementation-evidence/design-screen-closure.yaml`의
상태가 `REVIEW_REQUIRED`이다. closure rows에 남은 implementation digests는
현재 source digest(`498f8508…d3eb`)와 일치하지 않는다. `MANIFEST.sha256`도 위
12개 파일에서 실패하며, 기존 flow receipt와 generated client를 현재 source에
귀속할 수 없다. 따라서 어떤 visual/AX/runtime 판정도 release artifact의
증거로 재사용할 수 없다.

필수 조치: 구현 변경을 멈춘 하나의 clean snapshot에서 MANIFEST, authority tree
digest, 94 route/state receipt 및 representative public/response/CAS/approval
visual+AX receipt를 모두 재생성하고, 동일 digest로 `sha256sum --check`, clean
extraction/archive parity 및 strict validator 완료 결과를 남겨야 한다.

### D-R2-002 (P0) — 브라우저에 raw runtime DTO가 남는 projection side-door

`apps/review-console/src/lib/server/screen-load.ts`와 public/response 동등
loader가 조회한 `data` 전체를 `ScreenRuntime.data`로 hydration payload에 함께
넣는다. `packages/ui/src/screen-projection.ts:386-430`의 `projectScreen`은
`runtime.projection`이 비어 있거나 known field가 없을 때
`specializedFields(screen.id, section.id, runtime.data)`를 다시 실행한다.
`packages/ui/src/screen-projection-specialized.ts`와
`view-models/cas-010.ts`/`cas-011.ts`는 `record(data)`/`record(operation)` 및
fallback `items`, `evidenceScopeIds`, `output`를 읽어 화면 필드를 만든다.
즉 서버가 typed envelope를 누락해도 브라우저가 DTO를 해석해 값/상태를
표시하며, authority의 "projection 부재 시 UNKNOWN/BLOCKED, raw DTO·field-name
추측 금지" 규칙을 우회한다. 현재 unit test도 이 compatibility path를
`projectScreen(... data: ...)`로 직접 검증한다.

필수 조치: 서버에서만 raw response를 typed, display-safe envelope로 변환하고
hydration에는 그 envelope와 safe receipt만 전달한다. client `projectScreen`은
envelope가 없거나 incomplete이면 scope·reason·owner·retry/reauth가 있는
UNKNOWN/BLOCKED만 반환해야 한다. raw DTO를 주입한 94-screen negative test와
SSR/hydration payload scan으로 DTO 값이 DOM/HTML에 나타나지 않음을 증명해야
한다.

### D-R2-003 (P1) — EMPTY projection이 성공 화면에서 빈 영역으로 사라짐

`packages/ui/src/components/sections/AuthorityRecordSection.svelte`는
`projection && projection.fields.length === 0`이고 `projection.state ===
"EMPTY"`이면 첫 상태 분기를 건너뛴다. runtime이 `success`이고 typed section
필드가 선언되어 있으면 뒤의 `runtime.state === "empty"`/`declaredFields.length
=== 0`도 거짓이어서 heading 아래 아무 상태·원인·복구 정보도 렌더하지 않는다.
계약 누락이 authority-confirmed empty처럼 보이므로 사용자가 다음 행동을
선택할 수 없다.

필수 조치: declared field가 있는데 EMPTY/known=0인 경우를 명시적으로
UNKNOWN/BLOCKED로 바꾸고 affected scope, owner, as-of/next-review, preserved
input 및 retry/reauth/offline/conflict action을 표시한다. success+empty,
partial/stale/error 각 상태의 DOM·focus·live-region 회귀 테스트를 추가해야 한다.

### D-R2-004 (P1) — 24개 collection 화면이 generic key/value 표로 축약됨

generated registry에 `DataCollection` section이 24개 존재한다. 실제
`packages/ui/src/components/sections/DataCollection.svelte`는 모두
`OperationData mode="table"`로 위임하고, `OperationData.svelte`는 label/value
2열만 표시한다. row-level record identity와 승인된 destination, revision/
freshness, filter scope·cursor pagination·result count 변화, row 오류/복구 및
keyboard action이 없다. 검색/사건/신호/source run/response attachment·receipt
동선에서 사용자가 원하는 레코드를 즉시 비교·열고 다음 행동으로 이어갈 수
없어 ten-second object→state→answer→evidence→next-action 목표를 충족하지
못한다.

필수 조치: collection archetype별 typed row VM과 화면별 renderer를 제공하고
각 행에 human label, state, asOf/revision/digest, server-owned destination,
filter/pagination 및 empty/filtered-empty/partial/stale/error/offline copy와
row-level focus/action을 연결해야 한다. generic `OperationData`는 유일한
collection renderer가 될 수 없다.

### D-R2-005 (P1) — unknown/error copy가 복구 가능한 상태 모델을 전달하지 않음

`OperationData.svelte`의 unknown field 문구는 "서버 권위 projection에 이
항목이 없어 확인이 필요합니다"로 고정되고, `AuthorityRecordSection.svelte`의
error/partial/blocked 문구도 affected scope, 담당 owner, 기준 시각/다음
재검토, 입력 보존 여부와 정확한 retry/reauth/offline/conflict action을
포함하지 않는다. 내부 operation path를 직접 보여주던 이전 경로는 줄었지만,
그 자리에 사용자가 결정할 수 있는 복구 정보가 채워지지 않았다.

필수 조치: section state envelope를 화면별 typed metadata(`scope`, `owner`,
`asOf`/`nextReviewAt`, `preservedInput`, `recoveryAction`)로 확장하고 상태별
copy, focus target, live announcement 및 재시도/취소/재인증 결과 receipt를
94-screen state matrix에서 검증해야 한다.

### D-R2-006 (P1) — navigation destination이 여전히 client route 규칙으로 추측될 수 있음

`packages/ui/src/local-actions.ts`는 server `runtime.destinations`가 없으면
`contextualTarget`, `staticTargets`, `fallbackTargets` 및 pathname 조합으로
href를 생성한다. 특히 CAS/SRC 내부 sibling route와 query identifier는
server-owned target의 expected version/digest·권한·현재 상태 binding 없이
브라우저에서 계산된다. typed destination이 누락된 stale/다른 객체 응답에서
사용자가 잘못된 record로 이동할 수 있고, authority의 action→destination
binding 및 no raw/guessed route 규칙을 충족하지 않는다.

필수 조치: action별 서버 envelope에 허용된 `href`, target identity, expected
version/digest, allowed state를 넣고 client는 그 값만 사용해야 한다. destination
없음은 UNKNOWN/BLOCKED와 복구 안내로 닫고, stale/other-case/IDOR·wrong-target
negative test를 추가해야 한다. 정적 공개 도움말 링크는 별도 authority-static
allowlist로 명시해 dynamic route fallback과 구분해야 한다.

### D-R2-007 (P1) — accessibility acceptance가 PUB-004 한 화면만 실제 실행함

`tests/e2e/acceptance/support.ts:11-16`은 모든
`ACCESSIBILITY_RESPONSIVE-*` 시나리오를 `PUB-004`로 매핑한다. 8개 테스트가
heading/landmark/overflow/focus를 확인하더라도 RSP-002..006의 field error와
draft preservation, REV-002/003 reason/reauth dialog, OPS-006 approval,
CAS-010/011 compact table/provenance, AUTH-004 및 나머지 89개 화면의 상태·포커스·
live-region·forced-colors·200/400% zoom을 증명하지 않는다. contract section
count와 PUB-004 fixture를 94-screen acceptance로 확대 해석할 수 없다.

필수 조치: 최소 public/CAS/response/review/ops/auth representative와 모든
distinct archetype에 대해 non-empty, empty, stale, offline, conflict,
validation/receipt 상태를 실제 DOM/AX로 실행하고 320/360/390/768/1024/1280@200%/
1440/1920 및 400% reflow, keyboard-only, reduced-motion, forced-colors evidence를
source digest와 묶어 저장해야 한다. dialog/drawer/async completion의
activeElement와 table header/data-label semantics를 함께 assertion해야 한다.

## Positive observations (non-blocking)

- `bun` UI check/unit suite는 재현 가능하게 PASS했고, common CSS에 skip-link,
  focus-visible, reduced-motion, forced-colors와 compact `data-label` 표 대안이
  있다.
- `AgentAnalysisProjection.svelte`의 visualization/provenance table에는
  compact용 `data-label`과 narrative 대안이 있어 CAS 접근성 방향은 이전보다
  개선됐다.
- `AuthorityRecordSection`은 일반적인 projection 부재에서 raw key/value를
  그대로 순회하는 경로를 제거하려는 의도가 보이며, 이를 D-R2-002의 hydration
  fallback까지 제거해야 한다.

## Verdict

현재 source는 타입/단위 수준에서는 안정적이지만 source freeze가 성립하지 않고,
브라우저 raw DTO side-door, EMPTY blank state, generic collection renderer,
복구 메타데이터 부재, client destination 추측, 단일 화면 accessibility
acceptance가 남아 있다. 위 blocker를 root 수정하고 동일 source digest로
visual/AX/runtime evidence를 재생성한 뒤 독립 재리뷰가 필요하다.

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```
