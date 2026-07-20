# 31. 화면 시스템과 페이지 Archetype

## 1. 화면 명세의 역할

`specs/ui/screen-catalog.yaml`은 화면 구현의 권위 있는 inventory다. 라우트 파일이 존재한다는 이유만으로 화면을 구현 완료로 간주하지 않는다. 각 화면은 다음 질문에 답해야 한다.

1. 누구를 위한 화면인가?
2. 사용자가 이 화면에서 어떤 결정을 내려야 하는가?
3. 첫 5초, 30초, 5분에 무엇을 이해해야 하는가?
4. 어떤 정보가 가장 중요하며 무엇은 보조 정보인가?
5. 어떤 행동이 가능하고 어떤 권한·gate가 필요한가?
6. loading·empty·partial·stale·error·conflict 상태는 무엇인가?
7. 어떤 API operation과 데이터 freshness에 의존하는가?
8. 모바일·키보드·스크린리더에서 어떻게 동작하는가?
9. 무엇을 측정하며 어떤 데이터는 수집하지 않는가?
10. 이 화면이 절대로 해서는 안 되는 표현과 행동은 무엇인가?

## 2. 페이지 archetype

### A-01. Evidence Landing

사용: 홈, 사건 상세, contract detail.

구조:

1. 상태·freshness·correction banner
2. 제목·요약
3. 확인된 사실 / 중요한 미확인 / 당사자 소명
4. 핵심 metric with context
5. 비교·방법론
6. evidence·원문
7. timeline·revision
8. 다음 탐색

핵심: headline보다 status와 limitation이 먼저다.

### A-02. Search Index

사용: 사례·계약·기관·업체·정정·통합 검색.

구조:

1. 명확한 scope와 coverage
2. query/filter
3. 결과 수와 적용 filter
4. 결과 list/table
5. pagination
6. empty/error/freshness
7. 저장·구독(허용 시)

필터는 URL에 반영되고 keyboard로 제거 가능해야 한다.

### A-03. Entity Detail

사용: 기관·업체·source·rule.

구조:

1. 공식 identity와 변경 이력
2. coverage
3. descriptive metrics
4. 관련 records
5. limitations
6. methods/source links

기관·업체의 도덕적 점수나 순위를 만들지 않는다.

### A-04. Policy / Long-form

사용: 방법론, 편집 정책, governance, privacy.

구조:

1. page title·version·effective date
2. 요약
3. 목차
4. long-form content
5. 관련 문서
6. change history·contact

본문 최대 폭과 heading hierarchy를 지킨다.

### A-05. Guided Form

사용: 정정 요청, 구독, response portal.

구조:

1. 목적·privacy·시간 안내
2. 단계 indicator
3. 한 단계의 논리적 질문
4. inline validation + error summary
5. draft/save 상태
6. check answers
7. explicit submit
8. receipt

“다음”과 “제출”을 명확히 구분한다.

### A-06. Queue

사용: signal, case, review, correction, job queue.

구조:

1. 업무 scope·SLA
2. saved view/filter
3. count·priority reason
4. density 조절 가능한 list/table
5. assignment/bulk action
6. selection details
7. empty/backlog/incident

bulk action은 reversible·low-risk 항목만 허용한다.

### A-07. Task-centered Workspace

사용: 내부 사건 workspace, correction workspace.

구조:

1. 사건 identity·state·version
2. global blockers/conflict
3. 로컬 task rail
4. 현재 task content
5. contextual right panel
6. save 상태·audit
7. next required task

탭 수를 줄이기 위해 작업을 다음 그룹으로 묶는다.

- Overview
- Investigation
- Authoring
- Review & Publication
- Records

### A-08. Decision Review

사용: review snapshot, publish confirmation, rule activation.

구조:

1. exact 대상과 snapshot/version
2. decision criteria
3. evidence/diff
4. unresolved blockers
5. reviewer identity·independence
6. reason 입력
7. approve/reject/hold
8. receipt

`assurance_level: STEP_UP` decision은 declared assurance gate와 서버 gate를 요구한다. 시각적 destructive confirmation만으로 Step-up을 추론하지 않는다.

### A-09. Operations

사용: source runs, jobs, provider, budget, kill switch, audit.

구조:

1. health/SLO
2. incident banner
3. time range·filters
4. metrics와 baseline
5. affected objects
6. safe action
7. runbook
8. immutable event history

색상만으로 상태를 전달하지 않는다.

### A-10. Auth / System

사용: sign-in, MFA, 403, session expired, 404.

구조:

- 현재 상황
- 사용자에게 미치는 영향
- 가능한 다음 행동
- security/support 경로
- draft 보존 여부

## 3. 화면 anatomy

모든 화면은 해당될 때 다음 landmark를 가진다.

```text
skip link
global header
primary navigation
breadcrumb
page header
status/freshness region
main content
contextual navigation or aside
related content
footer
live region for async result
```

내부 workspace는 `main`을 하나만 사용하며, task rail과 context panel은 명확한 label을 가진다.

## 4. 정보 우선순위

### 4.1 공개 사건 상세

고정 순서:

1. 현재 공개 상태
2. 실제로 관찰된 사실
3. 가장 중요한 미확인 사항
4. 당사자 소명
5. 비교 맥락과 계산
6. 반대 근거
7. 원문과 provenance
8. 방법론·revision

이 순서를 “더 멋져 보이는 차트” 때문에 바꾸지 않는다.

### 4.2 Signal detail

고정 순서:

1. source/rule freshness
2. deterministic calculation
3. blocker·data quality
4. cohort distribution
5. raw provenance
6. related/duplicate
7. AI suggestion
8. triage decision

AI summary가 첫 카드가 되면 안 된다.

### 4.3 Review screen

고정 순서:

1. snapshot identity
2. blocker
3. change diff
4. claim-evidence-response
5. legal/editorial checklist
6. decision

## 5. 상태 모델

모든 data screen은 다음 공통 상태를 명세한다.

| 상태 | 의미 | UI 요구 |
|---|---|---|
| initial loading | 첫 데이터 | skeleton은 실제 layout을 반영 |
| refreshing | 기존 데이터 재검증 | 기존 내용을 유지하고 갱신 표시 |
| empty | 유효한 0건 | coverage와 다음 행동 |
| filtered empty | filter 결과 0건 | filter 제거 |
| partial | 일부 source/field 실패 | 영향 범위와 누락 |
| stale | freshness SLA 초과 | 마지막 정상 시각 |
| error | 요청 실패 | reference ID, 재시도 |
| unauthorized | 인증 필요 | sign-in, return URL |
| forbidden | 권한 없음 | request access 또는 관리자 |
| conflict | expected_version 불일치 | diff·reload·draft 보존 |
| offline | network 없음 | read cache/draft 상태 |
| success | command 완료 | receipt와 다음 단계 |
| degraded | incident 중 | 안전한 read-only mode |

component 하나의 generic spinner로 모든 상태를 처리하지 않는다.

## 6. 행동 분류

### Read action

- 링크, filter, tab, evidence drawer
- 즉시 수행
- URL/keyboard semantics 유지

### Draft action

- 자동 저장 또는 명시적 저장
- 저장 상태와 last saved 표시
- 충돌 시 조용히 overwrite 금지

### Reversible command

- assign, label, low-risk status
- undo 또는 명확한 reversal 제공

### High-impact command

- publish, retract, legal hold, role grant, kill switch
- exact target
- 영향 설명
- reason
- expected version
- declared assurance gate
- idempotency key
- 서버-side authorization/gate
- receipt

## 7. 화면 definition of ready

화면은 다음이 모두 있을 때 구현 준비 상태다.

- screen ID와 canonical route
- surface와 access
- archetype
- primary job과 사용자 질문
- section order
- action catalog
- state matrix
- API operation readiness
- content pattern
- permissions
- analytics event
- responsive behavior
- accessibility acceptance
- prototype 또는 wireframe
- product owner approval

## 8. 화면 definition of done

- catalog와 route가 일치
- 모든 READY operation을 generated client로 호출
- handwritten parallel DTO 없음
- loading/empty/partial/stale/error/conflict 구현
- keyboard walkthrough 통과
- 200% zoom 및 reflow 통과
- screen reader landmark/heading/forms 통과
- declared assurance-level server gate 테스트
- analytics payload에 금지 데이터 없음
- visual regression이 주요 viewport에서 통과
- usability acceptance task 통과
- 문구가 copy guideline과 일치
- screenshot만이 아니라 구현 evidence를 남김

## 9. Codex 금지사항

Codex는 다음을 임의로 결정하지 않는다.

- dashboard KPI
- status 색상 의미
- navigation label
- 공개 사건 제목
- filter 기본값
- 기관·업체 순위
- AI summary 위치
- destructive confirmation 방식
- response consent wording
- empty/error 문구
- 모바일에서 제거할 정보
- analytics event payload
- endpoint를 임의로 추가하거나 mock success로 대체

제품·화면·API·권한에 미결정 항목을 남기지 않는다. 실제 배포값만 `docs/open-decisions.md`의 deployment inputs로 관리한다.
