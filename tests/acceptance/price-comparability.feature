@hard-gate @final @data
Feature: 가격 이상 규칙은 비교 가능한 cohort만 사용하고 불명확성은 차단한다

  Background:
    Given 합성 price target 계약과 비교 계약 12건이 정규화돼 있다
    And rule version은 "1.0.0"이다

  # scenario-id: AC-PRICE_COMPARABILITY-001
  Scenario: 정확한 비교군으로 가격 이상 신호를 만든다
    When PRICE_OUTLIER 규칙을 실행한다
    Then cohort에는 합성 비교 계약 12건만 포함된다
    And 중앙값은 480000 KRW이다
    And 대상 단가는 2400000 KRW이다
    And ratio는 5.0이다
    And blocker는 없다
    And publishability는 "ELIGIBLE_FOR_INVESTIGATION"이다
    And 이 값은 부패 확률로 노출되지 않는다

  # scenario-id: AC-PRICE_COMPARABILITY-002
  Scenario: known bundle은 단품 cohort에서 제외한다
    Given 대상이 설치, 교육, 36개월 유지보수를 포함한 "KNOWN_BUNDLE"이다
    When 단품 가격 규칙을 실행한다
    Then PRICE_OUTLIER 신호는 생성되지 않는다
    And exclusion reason은 "KNOWN_BUNDLE_EXCLUDED"로 추적된다

  # scenario-id: AC-PRICE_COMPARABILITY-003
  Scenario: bundle이 불명확하면 ratio가 커도 차단한다
    Given 대상 bundle status가 "UNKNOWN"이다
    When 규칙을 실행한다
    Then signal blocker는 정확히 "BUNDLE_UNKNOWN"을 포함한다
    And publishability는 "BLOCKED"이다

  # scenario-id: AC-PRICE_COMPARABILITY-004
  Scenario: SET과 EA를 환산 근거 없이 비교하지 않는다
    Given 대상 단위는 "SET"이고 cohort 단위는 "EA"이다
    And authoritative conversion factor가 없다
    When 규칙을 실행한다
    Then blocker는 "UNIT_INCOMPATIBLE"이다
    And 시스템은 1 SET을 1 EA로 추측하지 않는다

  # scenario-id: AC-PRICE_COMPARABILITY-005
  Scenario: VAT unknown을 기본값으로 바꾸지 않는다
    Given 대상 VAT basis가 "UNKNOWN"이다
    When 규칙을 실행한다
    Then blocker는 "VAT_UNKNOWN"이다
    And 대상 가격을 VAT included로 정규화하지 않는다

  # scenario-id: AC-PRICE_COMPARABILITY-006
  Scenario: 취소 계약은 가격·지출 cohort에서 제외한다
    Given 대상 contract status가 "CANCELLED"이다
    When 규칙을 실행한다
    Then blocker는 "CONTRACT_CANCELLED"이다
    And 지출 합계에 포함하지 않는다

  # scenario-id: AC-PRICE_COMPARABILITY-007
  Scenario: 작은 표본은 높은 ratio만으로 eligible이 아니다
    Given 비교 가능한 observation이 2건뿐이다
    And provisional ratio는 8.0이다
    When 규칙을 실행한다
    Then blocker는 "INSUFFICIENT_DATA"이다
