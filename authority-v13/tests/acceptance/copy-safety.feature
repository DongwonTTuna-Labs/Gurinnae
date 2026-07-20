@hard-gate @final @editorial
Feature: 공개 문구는 이상 징후와 범죄 판정을 혼동하지 않는다

  # scenario-id: AC-COPY_SAFETY-001
  Scenario Outline: 자체 범죄 단정 표현을 차단한다
    Given official outcome이 없는 draft claim에 "<phrase>"가 있다
    When publication copy lint를 실행한다
    Then legal/editorial hard review flag가 발생한다
    And 자동 공개할 수 없다

    Examples:
      | phrase          |
      | 비리를 저질렀다 |
      | 세금을 해먹었다 |
      | 업체와 유착했다 |
      | 뇌물을 받았다   |
      | 사기 계약이다   |

  # scenario-id: AC-COPY_SAFETY-002
  Scenario: 가격 차이를 정확한 조건과 함께 표현한다
    Given 대상 2400000원, 중앙값 480000원, 표본 12, VAT 포함, 동일 단위다
    When approved comparison copy를 만든다
    Then 문장에 기간, 비교 조건, 표본, ratio와 limitation이 있다
    And 인터넷 최저가만을 근거로 사용하지 않는다

  # scenario-id: AC-COPY_SAFETY-003
  Scenario: 기관 사례 0건을 청렴으로 표현하지 않는다
    Given 선택 기간과 coverage에서 공개 사례가 0건이다
    When agency page의 empty state를 표시한다
    Then "수집·분석 범위 내 공개 사례 0건"이라고 표시한다
    And "비리가 없다" 또는 "청렴하다"라고 표시하지 않는다

  # scenario-id: AC-COPY_SAFETY-004
  Scenario: 공식 결과는 attribution 범위를 갖는다
    Given verified 감사 문서가 절차상 위반을 확인했다
    When OFFICIALLY_CONFIRMED 문구를 만든다
    Then 기관, 문서, 날짜, 정확한 확인 범위를 attribution한다
    And 문서가 말하지 않은 범죄 의도를 추가하지 않는다
