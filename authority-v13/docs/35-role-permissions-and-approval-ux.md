# 35. 역할·권한·승인 UX

## 1. 목적

권한은 메뉴 숨김이 아니라 서버가 강제하는 정책이다. UI는 사용자가 왜 행동할 수 있거나 없는지 설명하고, separation of duties를 명확하게 보여줘야 한다.

## 2. 역할

| 역할 | 핵심 책임 |
|---|---|
| `ANONYMOUS` | 공개 정보 읽기 |
| `SUBSCRIBER` | 이메일 구독 관리 |
| `RESPONSE_PARTY` | token 범위의 소명 제출 |
| `TRIAGER` | signal 검토·승격·반려 |
| `INVESTIGATOR` | case·hypothesis·evidence 작성 |
| `EDITOR` | claim·public copy·response 반영 |
| `LEGAL_REVIEWER` | 법률·개인정보 검토 |
| `PUBLISHER` | 승인된 snapshot 게시 |
| `DATA_OPERATOR` | source·run·replay 운영 |
| `RULE_ANALYST` | rule 평가·version 제안 |
| `OPERATIONS` | job·budget·provider·incident |
| `SECURITY_ADMIN` | kill switch·security response |
| `ACCESS_ADMIN` | 사용자·역할 grant |
| `AUDITOR` | read-only audit 접근 |
| `EXECUTIVE_APPROVER` | 매우 높은 위험의 예외 또는 조직 결정 |

역할은 직급이 아니라 capability bundle이다. 한 사람이 여러 역할을 가질 수 있지만 특정 결정에서는 separation of duties를 적용한다.

## 3. 주요 capability

```text
signals.read
signals.triage
cases.read
cases.create
cases.investigate
evidence.create
evidence.verify
claims.author
responses.request
responses.review
review.editorial
review.legal
publication.preview
publication.publish
publication.correct
publication.retract
sources.operate
rules.propose
rules.activate
jobs.operate
budgets.manage
kill_switch.execute
audit.read
users.manage
roles.grant
```

## 4. Separation of duties

기본 규칙:

- claim 주요 작성자는 동일 snapshot의 독립 editorial reviewer가 될 수 없다.
- investigator 혼자 publication을 게시할 수 없다.
- rule 제안자는 production activation의 유일 승인자가 될 수 없다.
- role grant 대상자가 자신의 grant를 승인할 수 없다.
- retraction은 최소 editor + publisher, 고위험은 legal review 필요.
- kill switch 범위가 넓으면 two-person approval.
- break-glass는 사후 audit와 만료를 요구.

UI는 conflict를 사전에 표시하며 서버가 최종 거부한다.

## 5. 권한 표현

### 허용 행동

primary button과 영향 설명을 제공한다.

### 권한 부족

경우에 따라:

- action을 disabled하고 필요한 role/조건 설명
- 민감한 기능 존재를 숨김
- access request 경로
- 관리자 연락

단순히 클릭 후 403을 보여주는 것을 정상 UX로 간주하지 않는다.

### 조건 미충족

권한은 있지만 gate가 부족한 경우:

```text
게시할 수 없음
- 기관 소명 요청 기한이 아직 종료되지 않았습니다.
- 최신 snapshot에 법률 검토가 없습니다.
- 2개의 factual claim이 근거 없이 남아 있습니다.
```

## 6. 고위험 행동 패턴

고위험 행동:

- 게시
- 철회
- 법률 hold
- 개인정보 긴급 제한
- role grant/revoke
- source destructive replay
- rule production activation
- kill switch
- budget limit 변경

요구:

1. exact object와 version
2. 영향 범위
3. prerequisites
4. reason code + note
5. declared assurance-level verification
6. expected version
7. idempotency key
8. server-side re-evaluation
9. audit event
10. receipt

색상과 “정말?” 확인창만으로는 불충분하다.

## 7. Reauthentication

다음 중 하나:

- OIDC step-up
- WebAuthn/security key
- MFA 재확인

비밀번호를 앱 자체에 다시 입력받지 않는 구성을 선호한다. reauth timestamp와 assurance level은 server에서 검증한다.

## 8. 승인 UX

### Review snapshot

승인은 mutable case가 아니라 immutable snapshot을 대상으로 한다.

표시:

- snapshot ID/hash
- 생성 시각
- 대상 case version
- included claim/evidence/response
- diff
- 만료 조건

### 조건부 승인

조건은 자유 text로만 남기지 않고 task로 구조화한다.

- required change
- owner
- due
- blocking 여부
- verification method

blocking 조건이 해결되면 새 snapshot과 재검토가 필요하다.

## 9. 접근 권한 요청

사용자는 다음을 제출한다.

- 필요한 capability
- 대상 범위
- 업무 이유
- 기간
- 관리자
- training/compliance 상태

grant는 가능하면 만료를 가진다. broad admin role보다 scope-limited role을 우선한다.

## 10. 사용자·역할 화면

### 사용자 상세

- identity provider status
- active sessions
- roles/scopes
- last access
- pending grants
- separation conflicts
- recent STEP_UP-authorized actions
- offboarding state

민감한 개인 활동을 성과 감시에 사용하지 않는다.

### 역할 정의

- capability list
- 대상 scope
- 사용 인원
- conflicting roles
- approver
- last review
- deprecated status

## 11. Break-glass

긴급 접근:

- 명시적 incident ID
- 최소 범위
- 짧은 만료
- 강한 reauth
- 실시간 security notification
- 모든 read/write audit
- 사후 review

UI에 평상시 shortcut처럼 노출하지 않는다.

## 12. 권한 오류 상태

- 401: sign-in/session 문제와 return path
- 403: 권한 또는 policy 이유
- 409: version/separation conflict
- 423: legal/incident lock
- 428: reauthentication required

오류는 내부 policy 세부사항을 필요 이상 공개하지 않지만 사용자의 해결 행동을 제공한다.

## 13. Acceptance

- UI와 서버 permission matrix가 일치한다.
- 메뉴 숨김만으로 권한을 구현하지 않는다.
- 자신의 작업을 독립 승인할 수 없다.
- stale snapshot 승인은 무효다.
- role 변경은 대상·기간·이유·승인·audit를 가진다.
- `assurance_level: STEP_UP` action은 recent reauth 없이 실패한다. `DESTRUCTIVE_CONFIRMATION`만인 action은 해당 operation의 assurance policy를 따른다.
- disabled action은 가능한 경우 이유를 설명한다.
- auditor role은 write command가 없다.
