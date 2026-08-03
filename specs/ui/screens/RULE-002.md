# RULE-002 — 규칙 버전 상세

상태: **FINAL / REQUIRED COMPLETE**  
Route: `/internal/rules/{ruleId}/versions/{version}`  
Surface: `internal`  
Access: `oidc`  
Archetype: `ENTITY_DETAIL`  
Test prefix: `rule_002`

## 사용자 목적

불변 rule version의 목적·입력·formula·cohort·blocker·change·owner를 검토한다.

## 이 화면이 즉시 답해야 하는 질문

- 이 version은 무엇이 바뀌었는가?
- 필수 field와 blocker가 무엇인가?
- 어떤 결과에 사용됐는가?

## Above-the-fold 순서

1. `identity`
2. `definition`
3. `cohort`
4. `blockers`

1440×900 wide viewport에서 사용자는 스크롤 전에 화면 목적, 객체 상태, 가장 중요한 답, 주요 행동, freshness 또는 blocker를 확인해야 한다.

## 최종 정보 순서

| 순서 | Section ID | 제목 | 구현 Component | 목적 |
|---:|---|---|---|---|
| 1 | `identity` | version identity | `StatusAndRevisionHeader` | status·owner·hash. |
| 2 | `definition` | 정의 | `GuidedFormSection` | input/formula/trigger. |
| 3 | `cohort` | cohort | `ComparisonWorkbench` | include/exclude. |
| 4 | `blockers` | blocker | `StructuredContentSection` | quality guard. |
| 5 | `diff` | version diff | `StructuredContentSection` | previous. |
| 6 | `usage` | 사용 | `SignalTriagePanel` | runs/signals/public cases. |
| 7 | `approval` | 승인 이력 | `RevisionTimeline` | reviewers. |

이 순서는 wide, medium, compact에서 의미적으로 동일하다. 화면 폭은 배치를 바꾸지만 중요도를 바꾸지 않는다.

## Layout

- Wide: 12-column grid; identity/coverage 12; main records 8 + context/limitations 4
- Medium: 8-column stacked grid
- Compact: single column; identity → coverage → metrics → records → limitations
- Container: `public_main`

## Actions

| Action ID | Label | Interaction | Assurance | Capability | Operation |
|---|---|---|---|---|---|
| `open-evaluation` | 평가 보기 | `NAVIGATION` | `NONE` | `none` | `local-only` |
| `create-draft` | 다음 버전 초안 | `COMMAND` | `ACTIVE_SESSION` | `rules.propose` | `createRuleVersionDraft` |
| `download-definition` | 정의 다운로드 | `DOWNLOAD` | `NONE` | `none` | `local-only` |

Primary action: `create-draft`

## Data contracts

| Operation | API | Method | Path | Request Schema | Response Schema |
|---|---|---|---|---|---|
| `getInternalRuleVersion` | `control-api` | `GET` | `/v1/internal/queries/get-internal-rule-version` | `getInternalRuleVersionQuery` | `InternalRuleVersionResponse` |
| `createRuleVersionDraft` | `control-api` | `POST` | `/v1/internal/commands/create-rule-version-draft` | `createRuleVersionDraftRequest` | `createRuleVersionDraftReceipt` |

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

- `internal.rule_version.viewed`
- `internal.rule_version.draft_created`

본문·magic token·scoped session·개인정보·첨부파일명·근거 원문은 analytics payload에 포함하지 않는다.

## 금지

- active version in-place 수정
- 평가 없는 변경

## Implementation files

- Page: `apps/review-console/src/routes/internal/rules/[ruleId]/versions/[version]/+page.svelte`
- Server load/actions: `apps/review-console/src/routes/internal/rules/[ruleId]/versions/[version]/+page.server.ts`
- Layout: `apps/review-console/src/routes/internal/+layout.server.ts`
- Error boundary: `apps/review-console/src/routes/+error.svelte`
- View model: `apps/review-console/src/lib/view-models/rule-002.ts`
- E2E: `tests/e2e/screens/rule-002.spec.ts`
- Visual: `tests/visual/rule-002.spec.ts`

## Acceptance

- Route와 access mode가 일치한다.
- Section 순서를 바꾸지 않는다.
- 모든 blocking operation을 generated client의 server-only wrapper로 호출한다.
- 모든 필수 상태를 실제 계약으로 구현한다.
- Compact에서 정보와 행동이 소실되지 않는다.
- 권한과 scoped session은 server가 다시 검사한다.
- Screen-specific 금지사항과 global editorial/security policy를 위반하지 않는다.
