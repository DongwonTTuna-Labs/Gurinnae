@hard-gate @final @security
Feature: 공개 서비스는 승인된 projection 외 데이터를 읽거나 유출하지 않는다

  # scenario-id: AC-PUBLIC_PRIVATE_BOUNDARY-001
  Scenario: public DB role은 editorial schema를 읽지 못한다
    Given public API의 production DB role이 있다
    When editorial.investigation_cases를 SELECT한다
    Then 데이터베이스가 권한 오류로 거부한다
    When public.cases를 SELECT한다
    Then 승인된 projection만 반환한다

  # scenario-id: AC-PUBLIC_PRIVATE_BOUNDARY-002
  Scenario Outline: private field는 public API에 없다
    Given published case가 내부적으로 <private_field>를 갖는다
    When public case endpoint를 호출한다
    Then response body 어디에도 <private_field> 값이 없다

    Examples:
      | private_field             |
      | internal_priority         |
      | model_confidence          |
      | investigator_private_note |
      | response_token            |
      | raw_object_storage_key    |
      | unresolved_entity_candidate |

  # scenario-id: AC-PUBLIC_PRIVATE_BOUNDARY-003
  Scenario: public ID로 unpublished 존재를 추측할 수 없다
    Given authenticated internal system에는 unpublished case가 있다
    When 익명 사용자가 guessed case ID로 public endpoint를 호출한다
    Then private 존재 여부를 구분하지 않는 public 404를 반환한다
    And timing/body로 상태를 유추하기 어렵다

  # scenario-id: AC-PUBLIC_PRIVATE_BOUNDARY-004
  Scenario: response portal에 third-party tracking이 없다
    When response token page를 연다
    Then third-party analytics, 광고, chat script 요청이 0개다
    And Referrer-Policy는 no-referrer이다
