# 04. 조사 사건 생명주기와 상태 머신

## 1. 목적

이 문서는 `AnomalySignal`이 어떻게 조사 case가 되고, 검토·소명·공개·정정·철회 상태를 거치는지 정의한다. 상태는 UI label이 아니라 권한·불변식·이벤트를 강제하는 domain contract다.

## 2. Aggregate 분리

다음 aggregate를 분리한다.

- `AnomalySignal`: 규칙 실행 결과. case가 없어도 존재.
- `InvestigationCase`: 조사 workflow와 evidence/claim 상태.
- `ResponseRequest`: 기관·업체 소명 lifecycle.
- `ReviewDecision`: 특정 snapshot/content hash에 대한 승인/반려.
- `Publication`: public identity와 revision pointer.
- `PublicationRevision`: immutable content snapshot.
- `Correction`: revision 간 변경 사유와 영향.

Case state가 `PUBLISHED`라는 이유로 publication body를 mutable하게 저장하지 않는다.

## 3. Case 상태 enum

```text
SIGNAL_DETECTED
TRIAGE
INVESTIGATING
AWAITING_RESPONSE
EDITORIAL_REVIEW
LEGAL_REVIEW
READY_TO_PUBLISH
PUBLISHED_ANOMALY
PUBLISHED_EXPLAINED
OFFICIALLY_CONFIRMED
CORRECTION_REVIEW
CORRECTED
RETRACTED
REFERRED_CONFIDENTIAL
DISMISSED_DATA_ERROR
DISMISSED_DUPLICATE
DISMISSED_EXPLAINED
CLOSED_INSUFFICIENT_EVIDENCE
ARCHIVED
```

### SIGNAL_DETECTED

Detector가 하나 이상의 signal을 만들었지만 사람이 case로 수락하지 않았다. 외부 비공개.

Required:
- source and rule run IDs
- dedupe key
- data quality summary

Allowed next:
- TRIAGE
- DISMISSED_DATA_ERROR
- DISMISSED_DUPLICATE

### TRIAGE

사람이 signal의 기본 identity, 중복, 데이터 오류, 조사 가치 여부를 검토한다.

Required to leave:
- triager
- reason code
- signal disposition

Allowed next:
- INVESTIGATING
- DISMISSED_DATA_ERROR
- DISMISSED_DUPLICATE
- DISMISSED_EXPLAINED
- CLOSED_INSUFFICIENT_EVIDENCE

### INVESTIGATING

공식 source, 비교군, 반대가설, missing information을 조사한다.

Required:
- owner
- investigation plan
- at least one hypothesis
- risk classification draft

Allowed next:
- AWAITING_RESPONSE
- EDITORIAL_REVIEW
- REFERRED_CONFIDENTIAL
- DISMISSED_DATA_ERROR
- DISMISSED_EXPLAINED
- CLOSED_INSUFFICIENT_EVIDENCE

`EDITORIAL_REVIEW`로 바로 가는 것은 대상이 비식별 aggregate거나 response가 불필요하다는 editor reason이 있을 때만 가능하다.

### AWAITING_RESPONSE

기관/업체에 verified response request를 보냈고 deadline 전이거나 답변을 검토 중이다.

Required:
- at least one ResponseRequest
- exact claim set shared
- deadline

Allowed next:
- INVESTIGATING (새 정보로 재조사)
- EDITORIAL_REVIEW (response 반영 또는 deadline 완료)
- CLOSED_INSUFFICIENT_EVIDENCE
- DISMISSED_EXPLAINED

### EDITORIAL_REVIEW

claim wording, evidence sufficiency, comparison validity, privacy, license, response를 검토한다.

Required:
- immutable case review snapshot hash
- claim set
- evidence bundle
- reproducibility result

Allowed next:
- INVESTIGATING
- AWAITING_RESPONSE
- LEGAL_REVIEW
- READY_TO_PUBLISH
- DISMISSED_EXPLAINED
- CLOSED_INSUFFICIENT_EVIDENCE

### LEGAL_REVIEW

high-risk flag 또는 editor 요청으로 법률 검토.

Required:
- risk questions
- legal reviewer identity
- reviewed snapshot hash

Allowed next:
- INVESTIGATING
- EDITORIAL_REVIEW
- READY_TO_PUBLISH
- REFERRED_CONFIDENTIAL
- CLOSED_INSUFFICIENT_EVIDENCE

법률 검토 memo 자체는 public evidence가 아니다.

### READY_TO_PUBLISH

필수 승인이 특정 content hash에 결합되어 있고 public projection dry-run이 통과했다.

Required:
- approved content hash
- required approvals active and not revoked
- response gate satisfied
- privacy/license/provenance checks pass
- public slug reserved

Allowed next:
- PUBLISHED_ANOMALY
- PUBLISHED_EXPLAINED
- EDITORIAL_REVIEW (content 변경/승인 만료)

이 상태에서 draft가 한 글자라도 바뀌면 기존 승인은 무효화되고 EDITORIAL_REVIEW로 돌아간다.

### PUBLISHED_ANOMALY

설명되지 않은 이상 징후와 한계를 public revision으로 공개.

Allowed next:
- CORRECTION_REVIEW
- OFFICIALLY_CONFIRMED
- RETRACTED
- ARCHIVED

### PUBLISHED_EXPLAINED

초기 signal이 있었으나 합리적인 설명·데이터 오류가 확인된 과정을 투명성/교육 목적으로 공개. 대상의 reputation을 불필요하게 해치지 않는지 검토해야 한다.

Allowed next:
- CORRECTION_REVIEW
- OFFICIALLY_CONFIRMED
- RETRACTED
- ARCHIVED

### OFFICIALLY_CONFIRMED

공식 감사·행정·수사·판결 source가 문제를 확인했다. 어떤 수준의 확인인지 별도 enum을 가진다.

```text
AUDIT_FINDING
ADMINISTRATIVE_SANCTION
INVESTIGATION_OPENED
INDICTMENT
COURT_JUDGMENT_NONFINAL
COURT_JUDGMENT_FINAL
POLICY_CORRECTION
```

이 상태는 “부패 확정” 단일 label이 아니다.

Allowed next:
- CORRECTION_REVIEW
- ARCHIVED

### CORRECTION_REVIEW

공개 내용에 대한 오류·새 evidence·privacy 요청을 검토한다. public page에는 위험도에 따라 review banner를 붙일 수 있다.

Allowed next:
- CORRECTED
- prior public state (no change)
- RETRACTED

### CORRECTED

새 PublicationRevision이 current가 되었고 Correction record가 연결됨. case는 corrected 뒤에도 조사 또는 official status를 유지할 수 있으므로 구현에서는 `publication_status`와 `case_investigation_status` 분리를 고려한다. 이 명세 enum은 API 단순화를 위한 composite public state이며 DB 모델은 orthogonal state를 권장한다.

Allowed next:
- CORRECTION_REVIEW
- OFFICIALLY_CONFIRMED
- ARCHIVED

### RETRACTED

핵심 내용이 더 이상 유지될 수 없어 current revision이 철회 notice로 교체됨. 이전 revision과 reason은 보존하되 개인정보 emergency에 따라 접근 제한 가능.

Allowed next:
- CORRECTION_REVIEW (복구 가능성이 있는 경우)
- ARCHIVED

### REFERRED_CONFIDENTIAL

공개보다 공식 신고·보안·제보자 보호가 우선이라 비공개 전달 절차로 전환. public 상태가 아님.

Allowed next:
- INVESTIGATING
- LEGAL_REVIEW
- CLOSED_INSUFFICIENT_EVIDENCE
- ARCHIVED

### Dismissed/Closed

- `DISMISSED_DATA_ERROR`: source/parse/unit/identity 오류
- `DISMISSED_DUPLICATE`: 기존 signal/case와 동일
- `DISMISSED_EXPLAINED`: 합리적 설명으로 public 필요 없음
- `CLOSED_INSUFFICIENT_EVIDENCE`: 의문은 남지만 공개 최소 요건 미달

Dismiss는 signal과 evidence를 삭제하지 않는다. rule evaluation과 false-positive 개선에 사용한다.

### ARCHIVED

활성 workflow 종료. immutable public/history는 유지. 다시 열려면 권한 있는 editor와 reason이 필요하다.

## 4. 상태 전이 공통 요구

모든 transition command:

```json
{
  "case_id": "case_...",
  "from_state": "INVESTIGATING",
  "to_state": "AWAITING_RESPONSE",
  "expected_version": 17,
  "reason_code": "RESPONSE_REQUIRED",
  "reason": "단가 구성 확인 필요",
  "actor_id": "user_...",
  "idempotency_key": "..."
}
```

서버는 다음을 검사한다.

- actor role과 case assignment/recusal
- current state/version
- allowed transition
- state-specific guards
- required artifacts
- approval snapshot hash
- conflict of interest
- no self-approval rule
- idempotency

성공 시 case version 증가와 `case.state_changed` outbox event가 같은 transaction에서 기록된다.

## 5. Transition guard 목록

### G-IDENTITY-VERIFIED

Named entity가 public path로 갈 때 agency/supplier identity가 verified.

### G-PROVENANCE-COMPLETE

모든 public claim leaf가 source field/page까지 연결.

### G-REPRODUCIBLE

계산 bundle을 clean environment에서 재실행하고 동일 result hash.

### G-BLOCKERS-CLEARED

단위, VAT, bundle, spec, duplication 등 공개 blocker 없음.

### G-COUNTER-HYPOTHESIS

합리적인 반대 설명과 결과가 기록됨.

### G-RESPONSE-COMPLETE

response received/reviewed 또는 deadline/exception 완료.

### G-EDITORIAL-APPROVAL

risk matrix에 필요한 editor approval이 current snapshot hash에 유효.

### G-LEGAL-APPROVAL

legal_required인 경우 current snapshot hash 승인.

### G-PRIVACY-LICENSE

PII scan/redaction와 source redistribution permission 통과.

### G-PUBLIC-PROJECTION

public payload schema, broken link, accessibility/content checks dry-run 통과.

## 6. Approval lifecycle

ReviewDecision enum:

```text
APPROVE
APPROVE_WITH_CONDITIONS
REQUEST_CHANGES
REJECT
RECUSE
REVOKE_APPROVAL
```

Approval은 다음 key에 결합된다.

```text
case_id + review_snapshot_hash + reviewer_role + policy_version
```

다음이 발생하면 자동 만료한다.

- claim/evidence/response/redaction 변경
- policy version의 material update
- identity merge/split
- rule recomputation이 수치를 바꿈
- source 정정 발견

## 7. ResponseRequest lifecycle

```text
DRAFT
VALIDATED
SENT
DELIVERED
DELIVERY_FAILED
ACKNOWLEDGED
EXTENSION_GRANTED
RESPONSE_RECEIVED
UNDER_REVIEW
INCORPORATED
CLOSED_NO_RESPONSE
CLOSED_WITHDRAWN
```

- `SENT`는 외부 provider accepted일 뿐 delivery 보장이 아니다.
- deadline은 `DELIVERED` 또는 공식 channel 성공 시점 기준.
- response token은 hashed storage, expiry, one-time rotation.
- 첨부 검사 실패 시 response text는 보존하되 attachment는 quarantine.

## 8. Publication lifecycle

Publication identity는 안정적인 `publication_id`와 slug를 가진다.

Revision fields:

- revision_number
- content_hash
- title/summary/body structured content
- claims/evidence public projection
- responses
- methodology/rule versions
- source timestamps
- redactions
- reviewer approvals reference
- created/published timestamps
- supersedes_revision_id

Publication status:

```text
DRAFT_PROJECTION
PUBLISHING
CURRENT
SUPERSEDED
RETRACTED
ACCESS_RESTRICTED
```

`PUBLISHING`에서 public projection write, search index, asset copy가 실패하면 transaction/saga가 `CURRENT`로 확정되지 않는다. retry는 idempotent하다.

## 9. Correction lifecycle

```text
REPORTED
TRIAGED
INVESTIGATING
DRAFTED
APPROVED
PUBLISHED
REJECTED
```

Reason codes:

```text
TYPO
BROKEN_LINK
SOURCE_UPDATED
CALCULATION_ERROR
UNIT_ERROR
IDENTITY_ERROR
OMITTED_CONTEXT
RESPONSE_ADDED
PRIVACY_REDACTION
LEGAL_RESTRICTION
METHODOLOGY_CHANGE
OTHER
```

Identity error는 자동 `CRITICAL` severity다.

## 10. 시간·SLA와 scheduler

- transition deadline은 DB에 UTC로 저장, UI는 Asia/Seoul 기준 표시
- overdue는 자동 공개를 만들지 않고 escalation event만 생성
- response deadline 만료는 `CLOSED_NO_RESPONSE`로 자동 전이할 수 있지만 editor review를 대체하지 않음
- approval은 30일 동안 publish되지 않으면 freshness review 필요
- source가 material update되면 관련 READY/PUBLISHED case에 revalidation job

## 11. Concurrency와 idempotency

- aggregate version compare-and-swap
- command idempotency table stores actor, route, request hash, response
- 같은 key에 다른 request hash는 409 conflict
- outbox event ID는 aggregate + version 기반 또는 UUID with unique constraint
- consumers는 event ID dedupe
- job lease는 owner, fencing token, expires_at; stale worker write 차단

## 12. 감사 이벤트

최소 event:

- case.created
- case.state_changed
- case.owner_changed
- signal.attached/detached
- evidence.added/verified/redacted
- claim.created/changed/removed
- response.requested/received/incorporated
- review.submitted/revoked
- publication.published
- publication.corrected/retracted
- identity.merged/split
- rule.recomputed
- legal_hold.applied/released

Audit payload에는 secret나 full private attachment를 넣지 않고 object reference와 hash를 쓴다.

## 13. 불법 전이 예시

- SIGNAL_DETECTED → PUBLISHED_ANOMALY
- INVESTIGATING → READY_TO_PUBLISH without response/editorial
- READY_TO_PUBLISH → PUBLISHED with changed content hash
- PUBLISHED → delete previous revision
- DISMISSED_DATA_ERROR → public page without reopen/review
- actor가 자기 draft의 유일 승인자
- model service account가 ReviewDecision 생성

이 경로는 UI 숨김만이 아니라 domain/service/DB constraint와 acceptance test로 막는다.

## 14. 복합 상태 구현 지침

운영 DB에서는 다음 orthogonal 상태를 권장한다.

```text
case_workflow_state
publication_state
official_status
correction_state
response_state (per request)
```

API의 `display_status`는 이들을 결정적으로 합성한다. 단일 enum column에 모든 조합을 억지로 넣어 migration을 어렵게 만들지 않는다. 다만 외부 schema에 정의된 허용 label은 유지한다.
