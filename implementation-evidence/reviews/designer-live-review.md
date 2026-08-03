# Designer live review — current source tree

REVIEWER: DESIGNER / INFORMATION_ARCHITECTURE / RESPONSIVE / ACCESSIBILITY
REVIEWED_AT_UTC: 2026-07-20
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
SOURCE_DIGEST_AT_REVIEW: `3b7a91a3ee9bddc10b2455f6f6e6502f35f50e933d2f9954a39bc66a1742ef7e`
VERDICT: `CHANGES_REQUIRED`

## 범위와 확인 방법

`DESIGN.md`의 ten-second screen contract, 94-screen closure, WCAG 2.2 AA,
320/768/1440 레이아웃 및 상태·오류 UX를 기준으로 현재 Svelte 공통 렌더러,
CAS 분석 projection, 상태/오류 컴포넌트와 브라우저 acceptance harness를
읽기 전용으로 대조했다. source는 수정하지 않았다.

실행 결과:

- `bun run --filter '@gurine/ui' check` — PASS (0 errors, 0 warnings)
- `bun run --filter '@gurine/ui' test` — PASS (4 files, 38 tests)
- `python3` `source_digest()` — `3b7a91a3…42ef7e`
- `sha256sum --check MANIFEST.sha256` — FAIL (25 files; UI/API/evidence/snapshots
  포함)

타입/단위 테스트 통과는 실제 94개 화면의 인지부하 없는 정보 접근이나
현재 source에 묶인 시각·접근성 evidence를 증명하지 않는다.

## Blocking findings

### D-LIVE-001 (P0) — source/evidence freeze가 성립하지 않음

`MANIFEST.sha256`가 현재 파일과 25건 불일치하고, 현재 source digest는
`3b7a91a3…42ef7e`이다. 기존 UI/CAS snapshots와 runtime receipts는 다른
세대 digest를 사용한다. 따라서 어떤 화면/레이아웃/상태의 visual·a11y
판정도 최종 source에 귀속되지 않는다.

필수 조치: 구현 freeze 후 MANIFEST/authority tree digest, 94 route/state
receipts와 CAS positive render/provenance receipts를 하나의 digest로 다시
생성하고 clean extraction/archive parity를 확인한다.

### D-LIVE-002 (P1) — projection 부재 시 raw DTO 필드 추측 경로가 남아 있음

`packages/ui/src/components/sections/AuthorityRecordSection.svelte:18-35,44-50`
은 projection이 없으면 `semanticRecords(runtime)`로 전체 `runtime.data`를
순회하고, 필드명을 정규화해 `valueFor()`로 값을 채운다. 이는 화면별 typed
VM과 UNKNOWN/BLOCKED fail-closed 계약을 우회하며, 누락된 API 응답에서도
사용자가 잘못된 필드와 오래된 값을 정상 사실로 읽게 할 수 있다.

필수 조치: projection/section envelope가 없거나 불완전하면 raw data를
렌더하지 말고 범위·원인·담당자·복구 action이 있는 UNKNOWN/BLOCKED만
표시한다. raw DTO를 주입한 회귀 테스트를 94개 화면에 추가한다.

### D-LIVE-003 (P1) — CAS 표의 compact 접근성 라벨이 손실됨

`packages/ui/src/components/sections/AgentAnalysisProjection.svelte:32-37,48-58`
의 시각화·provenance 표는 `<thead>`에만 열 이름을 두고 `<td>`에
`data-label`/headers 연결을 하지 않는다. 공통 CSS
`packages/ui/src/styles/styles.css:1300-1348`는 compact에서 `thead`를 숨기고
각 행을 block으로 바꾸므로 320px/200% 환경에서는 값만 연속해 읽히며
"출발/관계/도착/근거 지문"을 알 수 없다. 이는 accessible table alternative
계약과 ten-second evidence 확인을 직접 깨뜨린다.

필수 조치: 각 셀을 정적 열 ID와 `headers` 또는 화면용 `data-label`에
결속하고, 모바일/스크린리더에서 동일한 열 의미가 유지되는 브라우저
assertion을 CAS-010/011 positive fixture로 추가한다.

### D-LIVE-004 (P1) — unknown 상태가 내부 operation path를 사용자에게 노출함

`packages/ui/src/components/OperationData.svelte:51-57`은 미확인 field의
`field.source`를 그대로 출력한다. projection source는
`operationId.path`(예: `getResponseDraft.$.status`) 형태이므로 사용자는
담당자·범위·재검토 시점 대신 내부 API 문자열을 해석해야 한다. 이는
인지부하 축소와 implementation path 비노출 규칙에 위배된다.

필수 조치: source path를 화면별 allowlist provenance label/scope/owner/
next-review metadata로 매핑하고, unknown/partial/stale/error마다 안전한
retry·reauth·offline 복구를 함께 표시한다.

### D-LIVE-005 (P1) — 접근성 acceptance가 실제 semantics를 검증하지 않음

`tests/e2e/acceptance/support.ts:12,60`은 모든
`ACCESSIBILITY_RESPONSIVE` 시나리오를 `PUB-004` 하나에 매핑한다.
`tests/e2e/acceptance/accessibility-responsive.spec.ts:13-17,29-33,45-49,
61-65,77-81,125-129,141-145,157-161`의 대부분 assertion은 section 수와
token 없는 URL뿐이다. heading/landmark, focus restoration, field association,
table header semantics, live announcements가 실제 DOM에서 검증되지 않아
94개 route와 CAS/response/approval 핵심 여정을 대표하지 못한다.

필수 조치: 최소 PUB-004, CAS-010, CAS-011, RSP-002..006, REV-002/003,
OPS-006, AUTH-004에 대해 realistic non-empty data로 compact/medium/wide,
200/400% zoom, keyboard-only, reduced-motion, forced-colors, error/stale/
offline/conflict 상태의 DOM/AX assertions와 source digest-bound receipts를
생성한다. generic contract smoke를 PASS 근거로 사용하지 않는다.

## 통과한 항목과 한계

공통 UI 타입체크와 38개 단위 테스트는 통과했다. 이는 컴파일·helper
정합성만 증명하며 위 P0/P1 문제를 해소하지 않는다. 위 findings가 닫히고
동일 최종 digest에 묶인 visual/AX/runtime evidence가 재검증되기 전에는
`LGTM_NO_BLOCKING`을 발행할 수 없다.

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```
