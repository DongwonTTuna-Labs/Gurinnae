# 33. 조사·편집 콘솔 제품 모델

## 1. 목표

내부 콘솔은 CRUD 관리자 페이지가 아니다. 조사자가 누락 없이 근거를 검증하고, 독립 편집·법률 review를 거쳐 안전하게 공개하도록 하는 **task-centered decision system**이다.

## 2. 콘솔의 핵심 객체

| 객체 | 사용자의 질문 |
|---|---|
| Signal | 어떤 결정적 규칙이 무엇을 발견했으며 데이터 품질은 충분한가? |
| Case | 어떤 조사 질문을 해결하고 있는가? |
| Hypothesis | 가능한 설명은 무엇이며 지지·반대 근거는 무엇인가? |
| Evidence | 출처가 무엇이고 어떤 claim을 지지·반박하는가? |
| Claim | 공개하려는 정확한 문장은 무엇인가? |
| Response | 당사자가 무엇을 답했고 어떤 부분을 검증했는가? |
| Review Snapshot | reviewer가 실제로 검토한 불변 버전은 무엇인가? |
| Decision | 누가 어떤 기준과 이유로 승인·반려했는가? |
| Publication Revision | 대외 공개된 불변 기록은 무엇인가? |
| Correction | 무엇이 왜 바뀌었는가? |

## 3. 내부 대시보드

대시보드는 vanity KPI가 아니라 작업 위험을 보여준다.

우선순위:

1. publication/correction blocker
2. 내게 배정된 기한 임박 작업
3. source/schema incident
4. response deadline
5. review backlog
6. DLQ·비용 budget
7. 일반 throughput

금지 KPI:

- “이번 주 의혹 N건”을 성과로 강조
- 조사자별 게시량 경쟁
- 가장 높은 가격 배수
- 기관별 signal 순위

## 4. My Work

사용자가 처리해야 할 task를 역할별로 합친다.

task 필드:

- task type
- 대상 객체
- 왜 내게 필요한지
- due/SLA
- blocker
- previous owner
- last change
- 바로 수행할 primary action

task는 source object 상태에서 파생되며 별도의 진실 원천이 되지 않는다.

## 5. Signal Queue

### 필터

- rule/version
- source
- detected time
- data quality
- blocker
- triage state
- duplicate likelihood
- amount range
- assignment

### 행 정보

- signal ID
- 간단한 관찰
- deterministic ratio/metric
- rule/version
- source freshness
- blocker
- comparison count
- assignment
- age

AI confidence는 기본 열이 아니다.

### bulk action

허용:

- assign
- low-risk label
- 동일 reason으로 명백한 duplicate 묶기(검토 가능)

금지:

- bulk publish
- bulk “corruption”
- 근거 없이 bulk dismiss
- 서로 다른 rule을 하나의 case로 자동 merge

## 6. Signal Detail / Triage

### 화면 순서

1. source·rule·freshness
2. 계산 입력과 결과
3. blocker·quality
4. cohort 분포와 제외
5. raw field provenance
6. related signals/cases
7. AI suggestion
8. decision form

### decision

- `DISMISS_DATA_ERROR`
- `DISMISS_EXPLAINED`
- `NEEDS_DATA`
- `LINK_TO_EXISTING_CASE`
- `PROMOTE_TO_CASE`
- `ESCALATE_IDENTITY_REVIEW`

각 decision은 reason code가 필요하다. 자유 text만으로는 부족하며 note는 보조다.

## 7. 사건 Workspace

사건 workspace는 많은 top-level 탭 대신 다음 task group으로 구성한다.

### 7.1 Overview

- case identity/state/version
- investigation question
- known / unknown / response
- readiness progress
- assignment and deadlines
- blockers
- next required action
- recent activity

### 7.2 Investigation

하위:

- linked signals
- hypotheses
- evidence
- entity/contract context
- agent runs

#### Hypothesis board

각 hypothesis:

- statement
- status
- supporting evidence
- contradicting evidence
- unresolved questions
- owner
- next action

가설을 “true/false”로 조기 확정하지 않고 `OPEN`, `SUPPORTED`, `WEAKENED`, `REJECTED`, `UNRESOLVED`를 사용한다.

#### Evidence matrix

행은 evidence, 열은 claim/hypothesis일 수 있다. 관계 유형:

- supports
- contradicts
- contextualizes
- provenance-only

AI가 만든 summary와 source evidence를 같은 type으로 취급하지 않는다.

### 7.3 Authoring

하위:

- claims
- public summary
- response management
- limitation statement

#### Claim editor

각 claim:

- 정확한 문장
- type: fact/calculation/editorial interpretation/party statement/official finding
- evidence IDs
- contradicting evidence
- confidence vocabulary(외부 확률 금지)
- public visibility
- language lint
- reviewer status

evidence 없는 factual claim은 저장 단계에서 invalid다.

#### Response management

- 대상 organization/contact
- 질문
- referenced claims/evidence
- due date
- delivery state
- reminder
- portal request
- submissions
- verification notes
- public excerpt/consent

### 7.4 Review & Publication

하위:

- readiness
- review snapshot
- publication preview
- decisions
- correction/retraction

readiness gate:

- identity verified
- units/bundle/VAT known or limitation
- comparison reproducible
- evidence accessible
- contradicting evidence reviewed
- response requested/handled
- privacy redaction
- prohibited language
- legal review if required
- independent editor review
- latest snapshot approval

### 7.5 Records

- timeline
- audit
- version history
- job/agent provenance
- related incident

## 8. 저장과 충돌

### Draft save

- local unsaved indicator
- server save timestamp
- autosave는 low-risk draft에 한정
- command는 autosave하지 않음
- navigation guard는 실제 unsaved change가 있을 때만

### Optimistic concurrency

충돌 시:

1. 사용자의 draft를 보존
2. 서버 최신 version과 변경자 표시
3. field-level diff 제공
4. overwrite 금지
5. reload/copy/merge 선택
6. merge 후 새 expected_version

## 9. Agent run UX

Agent run은 마법 같은 chat 창이 아니다.

표시:

- 목적
- 입력 evidence IDs
- prompt/policy version
- model/provider
- 시작·종료·비용
- structured output
- schema validation
- cited source
- rejected/accepted suggestions
- prompt injection flags
- human action

사용자가 AI 출력 일부를 claim/evidence로 채택할 때 provenance와 검증 상태를 명시한다.

## 10. Review Queue

행:

- case/title
- review type
- snapshot hash/version
- risk flags
- response state
- due
- reviewer independence
- changes since prior review

reviewer는 자신의 작성 작업을 독립 review로 승인할 수 없다.

## 11. 독립 Review 화면

### 상단

- snapshot ID/hash
- case version
- 생성 시각
- 작성자
- reviewer role
- stale 여부

### 본문

- public preview
- claim-evidence-response matrix
- diff from previous
- unresolved limitation
- legal/privacy flags
- source freshness

### decision

- approve
- approve with conditions(조건은 machine-readable task로 생성)
- request changes
- reject
- legal hold

승인 후 claim/evidence가 바뀌면 승인 자동 무효화.

## 12. Publish confirmation

게시 직전 화면은 다음을 다시 계산한다.

- latest version
- required reviews
- stale source
- unresolved blockers
- response deadline
- public redaction
- route/slug
- notification impact
- cache/projection readiness

사용자는 exact title, state, revision을 입력하거나 강한 confirmation을 수행한다. `assurance_level: STEP_UP`일 때만 declared assurance gate가 필요하다.

## 13. Source 운영 UX

### Source registry

- status
- owner
- last successful sync
- next scheduled
- schema version
- lag
- quarantine
- affected rules

### Schema drift

- old/new payload diff
- added/removed/type-changed fields
- sample count
- parser impact
- normalized field impact
- rule impact
- public freshness impact
- proposed mapping
- shadow parse result

replay/backfill은 예상 건수·기간·중복 전략·비용·rollback을 보여준다.

## 14. Rule 관리 UX

규칙 version은 불변이다.

- purpose
- formula
- cohort
- blocker
- threshold
- eval result
- shadow result
- estimated affected signal
- approver
- activation time
- rollback target

threshold slider를 움직이는 즉시 production에 반영하지 않는다.

## 15. 운영·보안 UX

### Kill switch

- scope
- 현재 상태
- 영향
- safe fallback
- reason
- expiry
- declared assurance gate
- two-person approval(범위에 따라)
- event receipt

### Role 관리

- role definition
- current grants
- requested change
- least privilege warning
- separation of duties conflict
- expiry
- approver
- audit

## 16. 내부 콘솔 acceptance

- 사용자가 다음 required task를 식별할 수 있다.
- AI output이 deterministic calculation보다 위에 있지 않다.
- evidence 없는 claim은 저장할 수 없다.
- stale snapshot으로 publish할 수 없다.
- reviewer independence 위반은 server에서 거부된다.
- conflict가 draft 손실 없이 해결된다.
- Step-up command는 reason·bounded authorization·receipt를 갖고, destructive confirmation은 별도의 UI interaction contract로 관리한다.
- private note가 public preview에 포함되지 않는다.
- 모든 command 결과가 audit event로 연결된다.
