# AUTH-003 — 접근 권한 없음

상태: **FINAL / REQUIRED COMPLETE**  
Route: `/auth/access-denied`  
Surface: `internal`  
Access: `authenticated`  
Archetype: `AUTH_SYSTEM`  
Test prefix: `auth_003`

## 사용자 목적

접근이 거부된 이유의 범주와 안전한 다음 행동을 이해한다.

## 이 화면이 즉시 답해야 하는 질문

- 로그인은 됐지만 왜 볼 수 없는가?
- 권한을 요청할 수 있는가?

## Above-the-fold 순서

1. `message`
2. `actions`
3. `reference`

1440×900 wide viewport에서 사용자는 스크롤 전에 화면 목적, 객체 상태, 가장 중요한 답, 주요 행동, freshness 또는 blocker를 확인해야 한다.

## 최종 정보 순서

| 순서 | Section ID | 제목 | 구현 Component | 목적 |
|---:|---|---|---|---|
| 1 | `message` | 권한 상태 | `StatusAndRevisionHeader` | 민감 객체 존재를 누출하지 않는 설명. |
| 2 | `actions` | 다음 행동 | `StructuredContentSection` | 내 작업·access request·지원. |
| 3 | `reference` | 참조 | `StructuredContentSection` | trace/request ID. |

이 순서는 wide, medium, compact에서 의미적으로 동일하다. 화면 폭은 배치를 바꾸지만 중요도를 바꾸지 않는다.

## Layout

- Wide: centered 5-column card within 12-column neutral canvas
- Medium: centered 6-column card
- Compact: full-width single-column panel with 16px margins
- Container: `form`

## Actions

| Action ID | Label | Interaction | Assurance | Capability | Operation |
|---|---|---|---|---|---|
| `request-access` | 접근 권한 요청 | `NAVIGATION` | `NONE` | `none` | `local-only` |
| `go-my-work` | 내 작업으로 | `NAVIGATION` | `NONE` | `none` | `local-only` |

Primary action: `request-access`

## Data contracts

| Operation | API | Method | Path | Request Schema | Response Schema |
|---|---|---|---|---|---|
| `getCurrentUserCapabilities` | `control-api` | `GET` | `/v1/internal/queries/get-current-user-capabilities` | `getCurrentUserCapabilitiesQuery` | `CurrentUserCapabilitiesResponse` |

모든 Submission operation은 raw bearer token을 canonical URL에 남기지 않는다. Magic token은 BFF가 one-time exchange에만 사용하고 이후에는 scoped submission session으로 전환한다.

## Required states

- `loading`
- `success`
- `empty`
- `partial`
- `stale`
- `error`
- `unauthorized`
- `forbidden`
- `conflict`
- `reauth-required`

상태가 달라도 동일한 정보 위계를 유지한다. Skeleton은 실제 content shape와 일치해야 하며 가짜 성공 값은 표시하지 않는다.

## Responsive contract

- Compact에서 주요 action과 critical unknown/blocker를 숨기지 않는다.
- Primary table은 의미가 보존되는 record list로 재배치한다.
- Context panel은 drawer 또는 inline section으로 이동하며 focus가 복원된다.
- Horizontal scrolling만으로 핵심 작업을 해결하지 않는다.

## Accessibility contract

- H1은 정확히 하나다.
- Section heading level을 건너뛰지 않는다.
- Keyboard만으로 전체 task를 완료할 수 있다.
- 최소 pointer target은 44×44 CSS px다.
- 상태는 색상에만 의존하지 않는다.
- Dialog/drawer 종료 후 원래 trigger로 focus를 되돌린다.
- Chart가 있으면 같은 사실을 담은 표 또는 문장형 대안을 제공한다.
- Save/submit/session exchange 결과를 적절한 live region으로 알린다.

## Analytics allowlist

- `internal.auth.access_denied_viewed`

본문·magic token·scoped session·개인정보·첨부파일명·근거 원문은 analytics payload에 포함하지 않는다.

## 금지

- 민감 객체 세부사항 누출
- UI 숨김만으로 권한 처리

## Implementation files

- Page: `apps/review-console/src/routes/auth/access-denied/+page.svelte`
- Server load/actions: `apps/review-console/src/routes/auth/access-denied/+page.server.ts`
- Layout: `apps/review-console/src/routes/internal/+layout.server.ts`
- Error boundary: `apps/review-console/src/routes/+error.svelte`
- View model: `apps/review-console/src/lib/view-models/auth-003.ts`
- E2E: `tests/e2e/screens/auth-003.spec.ts`
- Visual: `tests/visual/auth-003.spec.ts`

## Acceptance

- Route와 access mode가 일치한다.
- Section 순서를 바꾸지 않는다.
- 모든 blocking operation을 generated client의 server-only wrapper로 호출한다.
- 모든 필수 상태를 실제 계약으로 구현한다.
- Compact에서 정보와 행동이 소실되지 않는다.
- 권한과 scoped session은 server가 다시 검사한다.
- Screen-specific 금지사항과 global editorial/security policy를 위반하지 않는다.
