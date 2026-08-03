# RULE-003 — 규칙 평가·섀도 실행

상태: **FINAL / REQUIRED COMPLETE**  
Route: `/internal/rules/{ruleId}/versions/{version}/evaluation`  
Surface: `internal`  
Access: `oidc`  
Archetype: `OPERATIONS`  
Test prefix: `rule_003`

## 사용자 목적

gold·false-positive·historical·shadow 결과와 threshold 민감도를 평가한다.

## 이 화면이 즉시 답해야 하는 질문

- 정확도와 오탐 유형은 무엇인가?
- threshold 변경이 몇 건에 영향을 주는가?
- shadow가 production과 어떻게 다른가?

## Above-the-fold 순서

1. `dataset`
2. `metrics`
3. `errors`
4. `threshold`

1440×900 wide viewport에서 사용자는 스크롤 전에 화면 목적, 객체 상태, 가장 중요한 답, 주요 행동, freshness 또는 blocker를 확인해야 한다.

## 최종 정보 순서

| 순서 | Section ID | 제목 | 구현 Component | 목적 |
|---:|---|---|---|---|
| 1 | `dataset` | 평가 자료 | `CoverageStatement` | version·coverage. |
| 2 | `metrics` | 품질 지표 | `StructuredContentSection` | precision/recall where valid. |
| 3 | `errors` | 오탐·누락 | `StructuredContentSection` | category/examples. |
| 4 | `threshold` | 민감도 | `StructuredContentSection` | distribution. |
| 5 | `shadow` | 병행 평가 | `StructuredContentSection` | count·cost·diff. |
| 6 | `limitations` | 한계 | `StructuredContentSection` | small sample/bias. |
| 7 | `signoff` | 검토 | `DecisionReviewPanel` | editorial/data. |

이 순서는 wide, medium, compact에서 의미적으로 동일하다. 화면 폭은 배치를 바꾸지만 중요도를 바꾸지 않는다.

## Layout

- Wide: internal 12-column dashboard; incident row first; health cards then tables/runbooks
- Medium: 8-column; critical incident full width
- Compact: single-column incident and bounded actions; dense diagnostics collapse
- Container: `workspace`

## Actions

| Action ID | Label | Interaction | Assurance | Capability | Operation |
|---|---|---|---|---|---|
| `run-evaluation` | 평가 실행 | `COMMAND` | `ACTIVE_SESSION` | `rules.propose` | `runRuleEvaluation` |
| `start-shadow` | 섀도 실행 | `COMMAND` | `ACTIVE_SESSION` | `rules.propose` | `startRuleShadow` |
| `open-sample` | 사례 보기 | `NAVIGATION` | `NONE` | `none` | `local-only` |

Primary action: `run-evaluation`

## Data contracts

| Operation | API | Method | Path | Request Schema | Response Schema |
|---|---|---|---|---|---|
| `getRuleEvaluation` | `control-api` | `GET` | `/v1/internal/queries/get-rule-evaluation` | `getRuleEvaluationQuery` | `RuleEvaluationResponse` |
| `runRuleEvaluation` | `control-api` | `POST` | `/v1/internal/commands/run-rule-evaluation` | `runRuleEvaluationRequest` | `runRuleEvaluationReceipt` |
| `startRuleShadow` | `control-api` | `POST` | `/v1/internal/commands/start-rule-shadow` | `startRuleShadowRequest` | `startRuleShadowReceipt` |

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

- `internal.rule_evaluation.viewed`
- `internal.rule_evaluation.started`
- `internal.rule_shadow.started`

본문·magic token·scoped session·개인정보·첨부파일명·근거 원문은 analytics payload에 포함하지 않는다.

## 금지

- 단일 accuracy로 공개 품질 단정
- eval fixture 수정으로 통과

## Implementation files

- Page: `apps/review-console/src/routes/internal/rules/[ruleId]/versions/[version]/evaluation/+page.svelte`
- Server load/actions: `apps/review-console/src/routes/internal/rules/[ruleId]/versions/[version]/evaluation/+page.server.ts`
- Layout: `apps/review-console/src/routes/internal/+layout.server.ts`
- Error boundary: `apps/review-console/src/routes/+error.svelte`
- View model: `apps/review-console/src/lib/view-models/rule-003.ts`
- E2E: `tests/e2e/screens/rule-003.spec.ts`
- Visual: `tests/visual/rule-003.spec.ts`

## Acceptance

- Route와 access mode가 일치한다.
- Section 순서를 바꾸지 않는다.
- 모든 blocking operation을 generated client의 server-only wrapper로 호출한다.
- 모든 필수 상태를 실제 계약으로 구현한다.
- Compact에서 정보와 행동이 소실되지 않는다.
- 권한과 scoped session은 server가 다시 검사한다.
- Screen-specific 금지사항과 global editorial/security policy를 위반하지 않는다.
