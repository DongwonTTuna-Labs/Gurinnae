@hard-gate @final @data @editorial
Feature: 업체·기관 식별의 불확실성을 보존하고 잘못된 merge의 영향을 정정한다

  # scenario-id: AC-ENTITY_RESOLUTION-001
  Scenario: 상호명만 같은 업체를 자동 merge하지 않는다
    Given 두 supplier record의 정규화 상호는 같다
    But authoritative identifier와 주소/대표 정보는 확인되지 않았다
    When entity resolver가 후보를 계산한다
    Then resolution status는 "AMBIGUOUS" 또는 "CANDIDATE"이다
    And 하나의 canonical supplier로 merge하지 않는다

  # scenario-id: AC-ENTITY_RESOLUTION-002
  Scenario: ambiguous supplier concentration은 공개 후보가 아니다
    Given concentration signal의 supplier identity가 "AMBIGUOUS"이다
    When signal publishability를 평가한다
    Then blocker는 "IDENTITY_AMBIGUOUS"이다
    And public supplier page나 관계 그래프를 만들지 않는다

  # scenario-id: AC-ENTITY_RESOLUTION-003
  Scenario: authoritative identifier로 merge를 승인한다
    Given 공식 사업자 식별자가 일치하고 검증됐다
    When 권한 있는 actor가 merge를 확정한다
    Then merge 근거, source, actor, version이 audit에 기록된다
    And 이전 aliases는 추적 가능하다

  # scenario-id: AC-ENTITY_RESOLUTION-004
  Scenario: 잘못된 merge를 되돌리면 영향 평가가 열린다
    Given merged supplier를 참조하는 public revisions가 2개 있다
    When merge가 reverted된다
    Then 자동으로 공개 내용을 바꾸지 않는다
    And 영향받는 2개 사건에 correction review를 생성한다
