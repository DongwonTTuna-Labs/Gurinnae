# 독립 디자이너 리뷰 — v13 현재 source snapshot

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```

ROLE: information architecture · responsive · accessibility · state/error UX · visual consistency  
REVIEWED_AT_UTC: 2026-07-20  
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`  
SOURCE_DIGEST_AT_REVIEW: `8c97934738da8efb2987948dc64fc0e91f170abb8987db20d864f4e347fc17ef`

## 검토 범위와 실행 증거

첨부된 v13 authority ZIP과 현재 worktree만 기준으로 94-screen registry,
screen projection/renderer, 공통 CSS, OPS-004 계약, responsive/accessibility
acceptance harness를 읽기 전용으로 검토했다. 소스 구현은 수정하지 않았다.

- `bun run --filter @gurine/ui check` — PASS (0 errors / 0 warnings)
- `bun run --filter @gurine/ui test --run` — PASS (5 files / 38 tests)
- `sha256sum --check MANIFEST.sha256` — FAIL (30 mismatches; `verification/generated-operation-samples.json` 포함)
- `python3 -B scripts/authority_tree_digest.py` — FAIL (`db/migrations/0030_v13_submission_session_hardening.sql` mismatch)
- `scripts/generate_pdm_flow_evidence.py::source_digest()` 재계산 — `8c979347…17ef`

현재 source digest가 handoff에서 보고된 `b4aa4bfe…`와도 일치하지 않아, 이
리뷰에서 관찰한 UI를 어떤 runtime/receipt/archive가 증명하는지 고정할 수 없다.
따라서 정적 컴파일·단위 테스트 통과는 시각/접근성 LGTM 근거로 승격하지 않는다.

## Blocking findings

### D-20260720-001 (P0) — 단일 source/evidence/archive freeze가 닫히지 않음

MANIFEST 검증과 authority tree digest가 실패하고, 현재 digest 자체도 이전
기록과 불일치한다. `tests/e2e/visual-routes.spec.ts`의 94×3 snapshot 파일은
현재 source digest에 귀속된 live DOM/AX 실행 receipt가 아니다. 구현 변경을
멈춘 뒤 MANIFEST, 94 route/state evidence, visual/AX 결과, clean extraction
parity를 같은 digest로 재생성하고, 각 결과에 digest와 실행 시각을 봉인해야
한다.

### D-20260720-002 (P0) — OPS-004가 authority와 비권위 Business Health 계약으로 갈라짐

authority ZIP의 OPS-004 순서는 `envelope → spend → forecast → limits →
alerts → changes`다. 그러나 현재
`specs/ui/screens/OPS-004.md`와 `packages/ui/src/screen-projection-ops.ts`는
authority에 없는 `business-health` section/필드를 추가하고
`BusinessHealthPanel`을 렌더한다. 반면
`apps/review-console/src/routes/internal/operations/budgets/screen.ts`는
6-section 순서를 사용한다. 생성 registry, 화면 VM, projection, snapshot이
서로 다른 정보 우선순위를 갖는 상태라 사용자가 예산 envelope 뒤에 어떤
질문(비용인지 상업 지표인지)을 먼저 답해야 하는지 일관되지 않다. 해당
상업 지표를 별도 승인된 closed operation으로 분리할지, authority에 맞춰
완전히 제거할지 결정하고 모든 screen/manifest/renderer/test를 동일 계약으로
재생성해야 한다.

### D-20260720-003 (P1) — generic collection renderer가 핵심 object→state→next action을 납작하게 만듦

`packages/ui/src/components/sections/DataCollection.svelte`는 collection을
`OperationData mode="table"`로만 위임하고, `OperationData`는 필드를 두 열
(`항목/값`)로 출력한다. 94개 중 PUB/CAS/SRC/OPS/ADM의 여러 목록 화면에서
row identity, object type, status/as-of/revision, cursor/count 변화,
row-level keyboard action, filtered-empty/partial/stale/offline 복구가 한눈에
연결되지 않는다. authority가 요구하는 검색·운영 동선의 빠른 인지를 위해
collection archetype별 typed row VM/renderer와 compact record-list 변환,
정렬/페이지 결과 live announcement, server destination binding을 구현하고
상태별 DOM/AX 증거를 남겨야 한다.

### D-20260720-004 (P1) — UNKNOWN/BLOCKED 상태가 정상 필드 위계보다 뒤에 표시됨

`AuthorityRecordSection.svelte`는 projection field 배열이 존재하면 값이
모두 unknown이어도 먼저 정상적인 `dl.semantic-facts`를 그린 뒤 하단에
error/stale/blocker 문구를 추가한다. `OperationData.svelte`도 공통 empty 문구와
unknown 목록을 사용해 scope, as-of, owner, retry/reauth/offline/충돌 복구를
화면별로 알려주지 않는다. 사용자는 “확인 필요” 숫자와 실제 오류/차단을
구별할 수 있어야 한다. 상태 envelope(원인·범위·마지막 확인 시각·다음 행동)를
해당 section 첫 콘텐츠로 우선 표시하고, known 값이 없는 경우 성공형 표/카드를
렌더하지 않도록 해야 한다.

### D-20260720-005 (P1) — 94-screen 접근성/반응형 증거가 대표 화면에 편중됨

`tests/e2e/acceptance/support.ts`의 8개 accessibility scenario는
PUB-004, RSP-003/002, CAS-011/010, OPS-004 등 일부 representative만
실행한다. route count 94와 94×3 golden screenshot 파일은 각 화면의 keyboard
task, dialog/drawer focus return, table/chart alternative, error recovery를
증명하지 않는다. 특히 CAS-010/011, INT-002 승인, REV 정정/게시, AUTH,
collection, OPS-004의 populated/empty/partial/stale/offline/conflict/error를
wide/medium/320·360·390 compact/200% zoom/forced-colors/reduced-motion에서
실제 DOM·AX로 실행하고 digest-bound receipt를 생성해야 한다.

### D-20260720-006 (P1) — Compact 내부 console에서 context rail이 본문을 밀어내며 drawer/focus 계약이 없음

`ScreenPage.svelte`와 `styles.css`는 compact에서 context rail을 `order: -1`로
본문보다 먼저 표시하고 task rail을 숨긴다. 이것은 authority의 “context panel은
drawer 또는 inline section으로 이동하고 focus를 복원” 요구를 충족하는 명시적
토글/drawer가 아니며, blocker·세션·연결 자료가 본문보다 먼저 반복되어 인지
부하를 늘린다. compact에서도 현재 task 선택, context 열기/닫기, Escape,
trigger focus return을 보장하고 unsupported write task는 안전한 read-only/
desktop-required 안내로 닫아야 한다.

### D-20260720-007 (P1) — visual matrix가 authority 시험 폭과 상태를 모두 포함하지 않음

`visual-routes.spec.ts`는 1440×900, 900×900, 360×800만 screenshot한다.
authority responsive contract의 320×568, 390×844, 768×1024, 1024×768,
1280×800, 1920×1080 및 200% zoom/large text/forced colors가 golden/live
matrix에 없다. wide/medium/compact에서 섹션 순서가 같다는 선언만으로는
긴 한국어·금액·ID·error banner가 잘리는지 검증할 수 없으므로, 대표 archetype과
핵심 94 routes에 해당 viewport/state matrix와 clean evidence를 남겨야 한다.

## 확인된 양호한 부분 (차단을 해소하지 않음)

- 공통 토큰은 종이색 canvas/ink/evidence blue/상태 색을 사용하고, 금지된
  leaderboard·위험순 패턴은 renderer에 보이지 않았다.
- `ScreenPage`/app shell에 skip link, 단일 H1, landmark, error summary,
  focus-visible, reduced-motion, forced-colors 규칙이 있다.
- 버튼/링크/입력의 44px baseline, 표 caption/scope, chart 대안 projection
  타입과 compact record-list CSS가 존재한다.
- UI 정적 검사와 38개 UI 단위 테스트는 현재 코드가 컴파일되고 projection
  회귀가 없음을 보여준다.

## LGTM 발행 조건

다음 네 가지를 같은 source digest로 독립 재검토해 모두 통과해야 한다.

1. MANIFEST/authority tree/source archive/clean extraction parity PASS.
2. OPS-004 business-health 경계를 한 가지 최종 계약으로 고정하고 94-screen
   registry와 renderer를 재생성.
3. 94 routes의 representative archetype 및 상태별 DOM/AX/visual evidence,
   compact drawer/focus/error recovery를 sealed receipt로 확보.
4. generic collection/unknown state의 정보위계와 server destination binding을
   수정하고 UI check·test 및 live matrix를 재실행.

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```
