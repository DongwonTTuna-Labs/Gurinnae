# 독립 디자이너 재리뷰 — 최신 source/evidence snapshot

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```

REVIEWED_AT_UTC: 2026-07-20 20:29–20:37  \
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`  \
SOURCE_DIGEST_AT_REVIEW_END: `d4e2c1aef58e67f8db7713cc57838220e70b25a35c9cc658874c01edef1330df`

이번 재리뷰도 첨부 v13 authority ZIP과 현재 worktree만 사용했으며 구현 소스는
수정하지 않았다. 재리뷰 중 다른 작업의 source 변경으로 digest가 계속 바뀌었기
때문에 위 digest는 이 결과를 유효하게 하는 종료 시점 pin이다. 이후 source가
한 바이트라도 바뀌면 본 verdict와 모든 UI evidence를 다시 만들어야 한다.

## 실행 결과

- `bun run --filter @gurine/ui check` — PASS, 0 errors / 0 warnings
- `bun run --filter @gurine/ui test --run` — PASS, 5 files / 38 tests
- `sha256sum --check MANIFEST.sha256` — FAIL, 5 files
  (`db/migrations/0030_v13_submission_session_hardening.sql`,
  `services/analysis-worker/src/analysis_source_fetch.rs`,
  `services/control-api/src/service/query_business.rs`,
  `services/control-api/src/service/specialized_group_6.rs`,
  `verification/generated-operation-samples.json`)
- `python3 -B scripts/authority_tree_digest.py` — FAIL at the migration mismatch

정적 UI 컴파일/단위 테스트는 통과했지만 MANIFEST/tree proof와 digest-bound
runtime/visual evidence는 닫히지 않았다.

## 최신 blocker

### D-R2-001 (P0) — source/evidence freeze 불가

현재 worktree에는 위 5개 checksum mismatch와 authority tree digest 중단이
있다. 94×3 golden screenshot 파일과 route-count assertion은 이 종료 digest의
실제 DOM/AX 결과를 증명하지 않는다. 최종 구현을 멈추고 같은 digest로 MANIFEST,
tree digest, 94-route runtime/visual/AX receipt, clean archive extraction parity를
재생성하기 전에는 디자인 LGTM을 발행할 수 없다.

### D-R2-002 (P0) — OPS-004 화면 계약이 권위와 분기됨

권위 ZIP의 OPS-004 정보 순서는 `envelope → spend → forecast → limits →
alerts → changes`인데 현재 `specs/ui/screens/OPS-004.md`는 `business-health`를
두 번째로 추가했다. `packages/ui/src/screen-projection-ops.ts`와
`StructuredContentSection.svelte`도 해당 비권위 section을 인식하지만,
`apps/review-console/.../budgets/screen.ts`는 6-section 권위 순서다. 같은
route가 registry/source에 따라 다른 above-the-fold 질문을 보여줄 수 있어
인지부하와 시각 위계가 결정되지 않았다. Business Health를 권위 화면에서
완전히 제거하거나 별도 승인된 route/operation으로 분리한 뒤 모든 manifest,
typed projection, renderer, screenshot, acceptance를 동일 계약으로 맞춰야 한다.

### D-R2-003 (P1) — collection 정보 구조가 generic 2열로 평탄화됨

`DataCollection.svelte` 24개 section은 `OperationData mode="table"`에 의존하고,
row identity/status/as-of/revision, 결과 count/cursor, row-level destination 및
filtered-empty/partial/stale/offline 복구를 archetype별로 보여주지 않는다.
검색·사건·출처·운영 동선에서 사용자가 “무엇인지→현재 상태→근거→다음 행동”을
한 번에 이어서 읽기 어렵다. typed row VM/renderer와 compact record-list,
keyboard actions, 결과 변화 live announcement를 추가하고 상태별 receipt로
검증해야 한다.

### D-R2-004 (P1) — UNKNOWN/BLOCKED/error 정보 위계가 불충분함

`AuthorityRecordSection.svelte`는 unknown field가 있어도 먼저 정상형
`semantic-facts`를 렌더한 뒤 아래에 blocker를 붙인다. `OperationData.svelte`의
공통 empty/unknown 문구도 scope, 마지막 확인 시각, 책임자, retry/reauth/
offline/conflict 다음 행동을 화면별로 설명하지 않는다. 상태 envelope를 해당
section 첫 콘텐츠로 표시하고, known 값이 없으면 성공형 카드/표를 만들지 않도록
해야 한다.

### D-R2-005 (P1) — 94개 화면 접근성/반응형 증거가 representative에 편중됨

`tests/e2e/acceptance/support.ts`는 8개 accessibility scenario를 소수 화면에
매핑한다. 320·360·390 compact, 768/1024 medium, 1440/1920 wide, 200% zoom,
forced-colors, reduced-motion, keyboard-only, dialog/drawer focus return,
populated/empty/partial/stale/error를 94개 전체 또는 각 distinct archetype별
실제 DOM/AX로 실행한 sealed receipt가 없다. 특히 OPS-004, CAS-010/011, INT-002,
REV, AUTH, response portal과 collection의 상태별 UX를 별도로 증명해야 한다.

### D-R2-006 (P1) — compact context rail이 본문보다 앞에 강제됨

`styles.css`의 compact 규칙은 `.context-rail { order: -1; }`로 blocker·세션·연결
자료를 task 본문보다 먼저 노출하고, drawer 토글 및 trigger focus return 계약은
없다. authority의 context panel responsive contract를 충족하려면 명시적
open/close, Escape, focus restore를 제공하고 복잡한 write task는 안전한
read-only/desktop-required 안내로 닫아야 한다.

## 긍정 확인 (차단을 대체하지 않음)

- UI check 0/0과 UI 단위 테스트 38/38.
- 공통 shell의 skip link, 단일 H1, focus-visible, reduced-motion,
  forced-colors 및 표 caption/scope가 존재한다.
- 44px touch target과 chart/table projection 타입이 정의되어 있다.

## LGTM 조건

source 변경을 멈춘 하나의 digest에서 위 P0/P1을 닫고, OPS-004 단일 계약,
MANIFEST/tree/archive parity, 상태별 94-screen DOM/AX/visual receipts를 다시
확인한 독립 디자이너 재리뷰에서 `DESIGN_VERDICT: LGTM`을 받아야 한다.

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```
