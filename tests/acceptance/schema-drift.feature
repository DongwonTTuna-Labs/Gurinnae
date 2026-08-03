@hard-gate @final @data @ops
Feature: upstream schema 변화는 조용한 오해석 대신 격리된다

  # scenario-id: AC-SCHEMA_DRIFT-001
  Scenario: optional additive field는 경고와 함께 처리한다
    Given 기존 required field가 모두 있고 새 optional field만 추가됐다
    When schema fingerprint를 비교한다
    Then change class는 "ADDITIVE_COMPATIBLE"이다
    And parser는 unknown field를 보존하거나 안전하게 무시한다
    And schema observation metric을 기록한다

  # scenario-id: AC-SCHEMA_DRIFT-002
  Scenario: required amount field가 사라지면 격리한다
    Given expected amount scalar가 없고 알 수 없는 nested object만 있다
    When parser가 문서를 처리한다
    Then SourceDocument status는 "QUARANTINED"이다
    And normalized Contract는 생성되지 않는다
    And source schema drift event와 alert가 발생한다

  # scenario-id: AC-SCHEMA_DRIFT-003
  Scenario: 이전 정상 public data에는 stale 표시를 한다
    Given source가 breaking drift로 중단됐다
    And 기존 승인 publication이 그 source를 참조한다
    When source freshness SLO를 넘는다
    Then public page는 마지막 정상 retrieval 시각과 지연 banner를 표시한다
    And 새 자료가 반영된 것처럼 표현하지 않는다

  # scenario-id: AC-SCHEMA_DRIFT-004
  Scenario: 새 parser activation 전 raw replay dry-run을 비교한다
    Given parser v2 후보가 있다
    When 격리된 sample과 과거 golden sample을 replay한다
    Then field-level diff와 count/amount reconciliation report를 생성한다
    And 사람 승인 전 production parser version을 바꾸지 않는다
