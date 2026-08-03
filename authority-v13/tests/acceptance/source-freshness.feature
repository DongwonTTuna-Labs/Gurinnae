@hard-gate @final @data @ui
Feature: source 지연과 누락을 숨기지 않는다

  # scenario-id: AC-SOURCE_FRESHNESS-001
  Scenario: freshness SLO를 충족한다
    Given source의 마지막 성공 수집이 SLO 안이다
    When source status를 조회한다
    Then status는 HEALTHY이고 마지막 성공 시각을 표시한다

  # scenario-id: AC-SOURCE_FRESHNESS-002
  Scenario: source가 stale이면 기존 page에 banner가 보인다
    Given 마지막 정상 수집이 SLO를 10배 초과했다
    When 그 source를 참조하는 case page를 연다
    Then 상단에 source 이름, 마지막 정상 시각, 영향 범위를 표시한다
    And "실시간"이라고 표현하지 않는다

  # scenario-id: AC-SOURCE_FRESHNESS-003
  Scenario: stale source로 새로운 사실 주장을 자동 공개하지 않는다
    Given source freshness가 policy threshold를 넘었다
    When 새 publication readiness를 평가한다
    Then block code "SOURCE_FRESHNESS_BLOCKED"가 발생한다
    And 이미 공개된 역사적 revision을 자동 철회하지는 않는다

  # scenario-id: AC-SOURCE_FRESHNESS-004
  Scenario: source 복구 후 stale banner를 검증 뒤 제거한다
    Given 새 수집은 성공했지만 reconciliation이 실패했다
    When public status를 계산한다
    Then stale/partial 상태를 유지한다
    When reconciliation과 schema validation도 통과한다
    Then 새 freshness 상태를 public projection에 반영한다
