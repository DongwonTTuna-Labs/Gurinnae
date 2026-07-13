@hard-gate @final @editorial
Feature: 공개 수정과 철회는 투명한 immutable revision으로 남는다

  # scenario-id: AC-CORRECTION_HISTORY-001
  Scenario: minor correction은 새 revision을 만든다
    Given publication revision 1이 공개돼 있다
    When 비교표 날짜 오기를 정정한다
    Then revision 2가 생성되고 supersedes revision 1을 참조한다
    And revision 1은 내부 감사에서 읽을 수 있다
    And public page에는 정정 시각·내용·영향이 표시된다

  # scenario-id: AC-CORRECTION_HISTORY-002
  Scenario: material correction은 결론 영향을 설명한다
    Given 계산 단위 오류가 확인됐다
    When material correction을 공개한다
    Then correction severity는 MATERIAL 또는 CRITICAL이다
    And 무엇이 틀렸고 제목·수치·결론에 어떤 영향이 있는지 표시한다
    And 재발 방지 조치가 audit/postmortem에 연결된다

  # scenario-id: AC-CORRECTION_HISTORY-003
  Scenario: 철회 URL은 이력 없는 404가 아니다
    Given 핵심 근거 오류로 publication을 철회했다
    When 사용자가 원 canonical URL을 연다
    Then 철회 notice, 이유, 날짜, revision history를 본다
    And 원래 주장이 더 이상 유효하지 않음을 명확히 본다

  # scenario-id: AC-CORRECTION_HISTORY-004
  Scenario: correction cache purge
    Given revision 1이 CDN에 cache돼 있다
    When corrected revision 2가 committed된다
    Then correction SLO 내에 canonical URL과 API가 revision 2를 반환한다
    And ETag/content hash가 바뀐다
