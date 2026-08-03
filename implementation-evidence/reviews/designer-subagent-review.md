# Designer 독립 리뷰 — current source tree

REVIEWER: DESIGNER / INFORMATION_ARCHITECTURE / ACCESSIBILITY_RESPONSIVE
REVIEWED_AT_UTC: 2026-07-20
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
VERDICT: `CHANGES_REQUIRED`

## 범위와 방법

단일 디자인 축인 `docs/DESIGN.md`와 v13 UI 계약을 기준으로 현재 source tree의
Svelte projection, section dispatch, 상태·오류·폼·반응형 CSS와 실행 증거를
독립 대조했다. 소스는 수정하지 않았다.

실행한 검증:

- `bun --filter @gurine/ui check` — PASS (0 errors, 0 warnings)
- `bun --filter @gurine/ui test` — PASS (4 files, 38 tests)
- `python3`로 `scripts/generate_pdm_flow_evidence.py::source_digest()` 재계산 —
  `73174ddfdfa5ca82aac603449e6b402209d8b9ef567a5a0463339d4c222e34b7`
- `sha256sum --check MANIFEST.sha256` — FAIL (36 checksums mismatch)
- `bunx playwright test tests/e2e/acceptance/accessibility-responsive.spec.ts` —
  포트 `127.0.0.1:29100`이 이미 사용 중이라 webServer 기동 전에 중단됨; PASS로
  간주하지 않음

## Blocker

### D-01 / P0 — source/evidence/manifest freeze가 성립하지 않음

현재 source digest는 `73174ddf…e34b7`인데 runtime journey receipts는 서로 다른
세대(`27300c…e5cf`, `65621d…3674`)를 기록한다. `MANIFEST.sha256`도 36개 파일에서
실제 내용과 불일치한다(예: `packages/ui/src/components/ScreenSection.svelte`,
`packages/ui/src/screen-projection.ts`, `specs/api/control-api.openapi.yaml`).
따라서 기존 디자인 LGTM·visual/runtime receipt는 현재 화면을 증명하지 않는다.
최종 source freeze 후 MANIFEST, 모든 94-route/state evidence를 한 PostgreSQL
세대에서 다시 만들고 source digest·correlation·archive parity를 재검증해야 한다.

### D-02 / P0 — 금지된 raw/generic fallback이 남아 있음

`packages/ui/src/components/sections/AuthorityRecordSection.svelte:18-34,44-50`은
projection이 없을 때 `semanticRecords(runtime)`로 전체 `runtime.data`를 읽고
필드명을 정규화해 추측한다(`valueFor`). 이는 `docs/DESIGN.md:75-76,93-96`의
generic `OperationData`/raw JSON/필드명 추측 금지 및
`specs/ui/effective-screen-contracts.yaml:15-21,97-103`의 screen-specific typed
view-model 계약을 직접 위반한다. projection이 비어 있거나 로드 실패한 경우에도
동일한 경로가 다시 활성화되지 않도록 fallback을 제거하고, 각 화면의 typed
projection이 없으면 SSR 단계에서 UNKNOWN + 원인/복구 상태로 fail closed해야 한다.
runtime.data를 넣은 회귀 테스트에서 브라우저 텍스트에 DTO 값이 0건임을 94개
화면에 대해 검증해야 한다.

### D-03 / P0 — 핵심 목록/근거 화면이 generic `OperationData`로 축약됨

`DataCollection.svelte:1-8`은 모든 DataCollection 화면을 단순 2열
`OperationData` 표에 위임한다. 실제 authority가 요구하는 pagination, result
count, filter scope/freshness, record-level destination/action, empty/error
복구는 표현하지 않는다. `OperationData.svelte:40-60`도 모든 도메인을 동일한
"서버 권위 projection" 카드/표로 표시하고 `field.source`를 그대로 사용자에게
노출한다(`source` 값은 `getResponseDraft.$.status` 같은 내부 operation/path일 수
있음). 이 구조에서는 사용자가 찾은 사건·계약·근거를 즉시 열거나, 왜
UNKNOWN인지 담당자/재검토 시점을 알 수 없어 인지부하 없는 여정 목표를 충족하지
못한다. DataCollection/EvidenceLedger/Decision/AI/Response 각 authored section에
화면별 typed component(링크·근거 라벨·상태·다음 행동·복구 포함)를 제공하고,
사용자용 provenance label을 별도 allowlist로 매핑해야 한다.

### D-04 / P1 — unknown/empty/error UX가 scope·owner·재검토 정보를 잃음

`OperationData.svelte:23-43`의 UNKNOWN/LOADING/STALE/ERROR/PARTIAL 문구와
대부분의 호출부의 기본 `emptyLabel`은 공통 한 줄만 제공한다. `docs/DESIGN.md:105-106`
요구인 UNKNOWN/NOT_APPLICABLE의 이유·담당자·재검토 시점·복구 경로가 필드별로
표시되지 않는다. `field.source` 원문을 사용자에게 내보내는 것으로 대체할 수
없다. 720 state occurrence 각각에 대한 human copy, owner/deadline, retry/refresh
or offline/reauth/conflict 경로를 typed contract와 runtime receipt로 고정해야
한다.

이는 권위 copy 기준(`docs/39-content-design-and-microcopy.md:116-145`)의
scope별 empty/freshness 문구와도 어긋나며, `docs/37-accessibility-inclusive-design.md:71-104`
의 표 pagination announcement 및 stale/partial notice 위치 조건을 공통 한 줄로
충족했다고 볼 수 없다.

### D-05 / P1 — 접근성 증거가 전체 화면/상태를 닫지 못함

현재 accessibility Playwright harness는 모든 시나리오를 `PUB-004` 하나에
매핑하고(`tests/e2e/acceptance/support.ts`의 `screenByJourney`), visual-routes는
94개 화면의 이미지 비교만 수행해 heading/name/live-region/focus/forced-colors
의미를 검사하지 않는다. 기존 freeze 문서의 대표 3화면 PASS는 나머지 91개와
loading/empty/partial/stale/error/offline/reauth/conflict 상태의 근거가 아니다.
94 routes × 320/360/390/768/1024/1280/1440/1920 및 200%/400% 확대,
keyboard-only, reduced-motion, forced-colors, dynamic text와 주요 상태별
focus/live-region/입력 오류 연결을 실제 브라우저 receipt로 생성해야 한다.

`docs/38-responsive-and-device-strategy.md:150-220`과
`docs/46-screen-composition-standard.md:20-65`가 요구하는 320px·200%/400%·긴
한국어 이름·pagination·Known/Unknown/Response 순서도 동일 matrix에 포함해야 한다.

## 통과한 항목과 한계

공통 UI 타입체크와 단위 테스트는 통과했으며, 이는 타입·projection helper의
정합성만 증명한다. 위 blocker가 닫히고 source/evidence freeze가 다시 바인딩되기
전에는 디자이너 `LGTM_NO_BLOCKING`을 부여할 수 없다.
