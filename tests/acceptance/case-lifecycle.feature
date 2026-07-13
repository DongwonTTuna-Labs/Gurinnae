@hard-gate @final @editorial
Feature: 사건 상태는 승인된 상태 머신과 낙관적 동시성으로만 변경된다

  # scenario-id: AC-CASE_LIFECYCLE-001
  Scenario: 허용된 조사 흐름
    Given 사건은 "SIGNAL_DETECTED" 상태이고 version 1이다
    When TRIAGER가 expected version 1로 "TRIAGE" 전이를 요청한다
    Then 사건은 "TRIAGE" 상태 version 2가 된다
    And actor, reason, before/after state가 audit에 기록된다

  # scenario-id: AC-CASE_LIFECYCLE-002
  Scenario: 정의되지 않은 전이를 거부한다
    Given 사건은 "SIGNAL_DETECTED" 상태이다
    When actor가 바로 "PUBLISHED_ANOMALY"로 전이를 요청한다
    Then 전이는 "INVALID_STATE_TRANSITION"으로 거부된다
    And 사건 version은 변하지 않는다

  # scenario-id: AC-CASE_LIFECYCLE-003
  Scenario: stale client의 변경을 거부한다
    Given 사건의 현재 version은 8이다
    When client가 expected version 7로 claim을 저장한다
    Then HTTP 409 conflict를 반환한다
    And server state를 last-write-wins로 덮어쓰지 않는다
    And client draft를 되살릴 수 있는 diff metadata를 반환한다

  # scenario-id: AC-CASE_LIFECYCLE-004
  Scenario: 종료된 데이터 오류 사건을 새 공식 문서로 다시 연다
    Given 사건은 "DISMISSED_DATA_ERROR" 상태이다
    And 새 source document가 기존 오류를 바로잡는다
    When 권한 있는 editor가 reopen reason과 source document ID로 재개한다
    Then 사건은 "TRIAGE" 상태의 새 version이 된다
    And 이전 dismissal은 audit history에 남는다

  # scenario-id: AC-CASE_LIFECYCLE-005
  Scenario: 공개 후 수정은 direct edit가 아니라 correction review로 들어간다
    Given 사건은 "PUBLISHED_ANOMALY" 상태이다
    When material 오류가 verified evidence와 함께 접수된다
    Then 사건은 "CORRECTION_REVIEW" 상태로 전이한다
    And public revision을 즉시 overwrite하지 않는다

  # scenario-id: AC-CASE_LIFECYCLE-006
  Scenario: DB direct mutation을 권한으로 차단한다
    Given application 외 일반 운영 DB role이 있다
    When 그 role이 investigation_cases.state를 직접 update하려 한다
    Then 데이터베이스가 권한 또는 guard로 거부한다
