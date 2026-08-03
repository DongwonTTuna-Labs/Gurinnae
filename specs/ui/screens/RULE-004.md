# RULE-004 — 규칙 활성화

상태: **FINAL / REQUIRED COMPLETE**  
Route: `/internal/rules/{ruleId}/versions/{version}/activation`  
Surface: `internal`  
Access: `oidc`  
Archetype: `DECISION_REVIEW`  
Test prefix: `rule_004`

## 사용자 목적

평가·shadow·영향·rollback을 검토해 version을 활성화·예약·rollback한다.

## 이 화면이 즉시 답해야 하는 질문

- 모든 quality gate가 충족됐는가?
- 예상 signal·비용·공개 영향은 무엇인가?
- 어떤 version으로 rollback하는가?

## Above-the-fold 순서

1. `target`
2. `gates`
3. `impact`
4. `schedule`

1440×900 wide viewport에서 사용자는 스크롤 전에 화면 목적, 객체 상태, 가장 중요한 답, 주요 행동, freshness 또는 blocker를 확인해야 한다.

## 최종 정보 순서

| 순서 | Section ID | 제목 | 구현 Component | 목적 |
|---:|---|---|---|---|
| 1 | `target` | 활성화 대상 | `StructuredContentSection` | version/hash. |
| 2 | `gates` | quality gate | `DecisionReviewPanel` | eval/shadow/review. |
| 3 | `impact` | 영향 | `SignalTriagePanel` | signals/cases/cost/source. |
| 4 | `schedule` | 일정 | `StructuredContentSection` | effective time. |
| 5 | `rollback` | rollback | `StructuredContentSection` | target/version. |
| 6 | `approval` | 승인 | `DecisionReviewPanel` | SoD·reauth. |
| 7 | `receipt` | 결과 | `DataCollection` | activation event. |

이 순서는 wide, medium, compact에서 의미적으로 동일하다. 화면 폭은 배치를 바꾸지만 중요도를 바꾸지 않는다.

## Layout

- Wide: 12-column internal content; immutable target/diff 8 + criteria/blockers/action 4 sticky
- Medium: 8-column stacked; action follows criteria
- Compact: single column; target summary → blockers → criteria → reason → decision
- Container: `workspace`

## Actions

| Action ID | Label | Interaction | Assurance | Capability | Operation |
|---|---|---|---|---|---|
| `activate` | 규칙 활성화 | `DESTRUCTIVE_CONFIRMATION` | `STEP_UP` | `rules.activate` | `activateRuleVersion` |
| `schedule` | 활성화 예약 | `DESTRUCTIVE_CONFIRMATION` | `STEP_UP` | `rules.activate` | `scheduleRuleActivation` |
| `rollback` | 이전 버전으로 되돌리기 | `DESTRUCTIVE_CONFIRMATION` | `STEP_UP` | `rules.activate` | `rollbackRuleVersion` |

Primary action: `activate`

## Data contracts

| Operation | API | Method | Path | Request Schema | Response Schema |
|---|---|---|---|---|---|
| `getRuleActivationReadiness` | `control-api` | `GET` | `/v1/internal/queries/get-rule-activation-readiness` | `getRuleActivationReadinessQuery` | `RuleActivationReadinessResponse` |
| `activateRuleVersion` | `control-api` | `POST` | `/v1/internal/commands/activate-rule-version` | `activateRuleVersionRequest` | `activateRuleVersionReceipt` |
| `scheduleRuleActivation` | `control-api` | `POST` | `/v1/internal/commands/schedule-rule-activation` | `scheduleRuleActivationRequest` | `scheduleRuleActivationReceipt` |
| `rollbackRuleVersion` | `control-api` | `POST` | `/v1/internal/commands/rollback-rule-version` | `rollbackRuleVersionRequest` | `rollbackRuleVersionReceipt` |

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

- `internal.rule_activation.viewed`
- `internal.rule.activated`
- `internal.rule.rolled_back`

본문·magic token·scoped session·개인정보·첨부파일명·근거 원문은 analytics payload에 포함하지 않는다.

## 금지

- slider 즉시 production 반영
- 제안자 단독 승인
- rollback 없음

## Implementation files

- Page: `apps/review-console/src/routes/internal/rules/[ruleId]/versions/[version]/activation/+page.svelte`
- Server load/actions: `apps/review-console/src/routes/internal/rules/[ruleId]/versions/[version]/activation/+page.server.ts`
- Layout: `apps/review-console/src/routes/internal/+layout.server.ts`
- Error boundary: `apps/review-console/src/routes/+error.svelte`
- View model: `apps/review-console/src/lib/view-models/rule-004.ts`
- E2E: `tests/e2e/screens/rule-004.spec.ts`
- Visual: `tests/visual/rule-004.spec.ts`

## Acceptance

- Route와 access mode가 일치한다.
- Section 순서를 바꾸지 않는다.
- 모든 blocking operation을 generated client의 server-only wrapper로 호출한다.
- 모든 필수 상태를 실제 계약으로 구현한다.
- Compact에서 정보와 행동이 소실되지 않는다.
- 권한과 scoped session은 server가 다시 검사한다.
- Screen-specific 금지사항과 global editorial/security policy를 위반하지 않는다.
