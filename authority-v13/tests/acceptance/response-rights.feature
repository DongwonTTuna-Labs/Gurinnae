@hard-gate @final @editorial @security
Feature: 기관·업체는 안전하게 소명할 기회를 받고 답변은 공정하게 반영된다

  # scenario-id: AC-RESPONSE_RIGHTS-001
  Scenario: response request는 정확한 질문과 기한을 포함한다
    Given 사건의 공개 후보 claims가 준비됐다
    When EDITOR가 response request를 승인한다
    Then 요청은 사건, 확인할 항목, 근거 개요, 기한, 연장 방법, 공개 정책을 포함한다
    And unpublished 사건의 불필요한 private note는 포함하지 않는다

  # scenario-id: AC-RESPONSE_RIGHTS-002
  Scenario: token은 URL에서 session으로 교환하고 재사용할 수 없다
    Given 유효한 response token이 있다
    When 당사자가 처음 token을 교환한다
    Then secure response session을 얻는다
    And browser URL과 referrer에서 token이 제거된다
    When 같은 one-time token을 다시 교환한다
    Then 요청은 거부된다

  # scenario-id: AC-RESPONSE_RIGHTS-003
  Scenario: 첨부는 검사 전 열리지 않는다
    Given 첨부 upload가 완료됐고 scan status가 PENDING이다
    When reviewer가 파일을 열려고 한다
    Then 다운로드/preview는 거부된다
    When scan status가 CLEAN이고 MIME/size 정책을 통과한다
    Then 권한 있는 reviewer만 isolated viewer로 열 수 있다

  # scenario-id: AC-RESPONSE_RIGHTS-004
  Scenario: public consent와 내부 검토 동의를 구분한다
    Given 당사자가 "SUMMARY_ONLY"에 동의했다
    When publication draft를 만든다
    Then 승인된 요약만 public projection에 포함된다
    And response full body와 attachment는 포함되지 않는다

  # scenario-id: AC-RESPONSE_RIGHTS-005
  Scenario: 무응답을 죄의 인정으로 표현하지 않는다
    Given response deadline까지 답변이 없다
    When public copy를 생성한다
    Then 문구는 "기한 내 답변을 받지 못했습니다"이다
    And "인정했다" 또는 "해명하지 못했다"가 포함되지 않는다

  # scenario-id: AC-RESPONSE_RIGHTS-006
  Scenario: material response가 늦게 도착하면 correction review를 연다
    Given 사건이 이미 공개됐다
    And 새 verified response가 핵심 claim을 약화한다
    When editor가 response를 사건에 연결한다
    Then 사건은 correction review로 들어간다
    And 기존 page를 조용히 삭제하거나 overwrite하지 않는다
