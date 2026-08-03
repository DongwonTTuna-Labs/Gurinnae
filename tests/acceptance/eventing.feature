@hard-gate @final @ops
Feature: 도메인 이벤트는 transactionally 전달되고 중복·역행에 안전하다

  # scenario-id: AC-EVENTING-001
  Scenario: 상태 변경과 outbox는 원자적이다
    Given 사건 transition transaction이 시작됐다
    When outbox insert가 실패한다
    Then 사건 state 변경도 rollback된다

  # scenario-id: AC-EVENTING-002
  Scenario: consumer crash 뒤 같은 이벤트를 다시 받는다
    Given consumer가 side effect를 commit한 뒤 ACK 전에 crash했다
    When 같은 event ID가 재전달된다
    Then inbox dedupe로 side effect를 반복하지 않는다
    And 이벤트는 최종 ACK된다

  # scenario-id: AC-EVENTING-003
  Scenario: aggregate version이 역행한다
    Given projection의 aggregate version은 8이다
    When version 7 이벤트가 도착한다
    Then projection을 덮어쓰지 않는다
    And stale event metric을 기록한다

  # scenario-id: AC-EVENTING-004
  Scenario: aggregate version gap을 reconciliation한다
    Given projection version은 8이다
    When version 10 이벤트가 도착하고 version 9가 없다
    Then event payload로 상태를 추측해 적용하지 않는다
    And authoritative aggregate snapshot replay를 요청한다

  # scenario-id: AC-EVENTING-005
  Scenario: malformed restricted event는 redacted DLQ로 간다
    Given RESTRICTED event payload가 schema를 위반한다
    When consumer가 validation한다
    Then event는 DLQ에 들어간다
    And 일반 운영 UI/log에는 raw private body가 노출되지 않는다
