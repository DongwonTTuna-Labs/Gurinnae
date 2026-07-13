@hard-gate @final @contract
Feature: Rust-generated OpenAPI와 TypeScript client

  # scenario-id: AC-OPENAPI_CODEGEN-001
  Scenario: OpenAPI 생성은 데이터베이스 없이 성공한다
    Given DATABASE_URL이 설정되지 않았다
    And 외부 네트워크가 차단되어 있다
    When cargo xtask openapi generate를 실행한다
    Then public과 control JSON이 생성되어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-002
  Scenario: public과 control spec은 별도 파일이다
    When OpenAPI 생성을 완료한다
    Then specs/generated/public-api.openapi.json이 존재해야 한다
    And specs/generated/control-api.openapi.json이 존재해야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-003
  Scenario: 모든 operation ID가 명시적이고 고유하다
    Given 두 generated spec이 있다
    Then 각 spec의 모든 operation은 operationId를 가져야 한다
    And 각 spec 안에서 중복 operationId가 없어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-004
  Scenario: public spec에 internal path가 없다
    Given generated public spec이 있다
    Then /v1/internal 경로가 없어야 한다
    And response submission write 경로가 없어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-005
  Scenario: control spec에 public entity read surface가 섞이지 않는다
    Given generated control spec이 있다
    Then public cases agencies suppliers 목록 경로가 없어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-006
  Scenario: public schema에는 editorial private field가 없다
    Given generated public spec의 모든 reachable schema가 있다
    Then internal notes와 reviewer identity와 private response contact field가 없어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-007
  Scenario: clean OpenAPI 재생성은 diff가 없다
    Given tracked generated OpenAPI가 현재 상태다
    When 임시 디렉터리에 다시 생성한다
    Then canonical content diff가 없어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-008
  Scenario: TypeScript public client는 public spec만 사용한다
    Given API client generation config가 있다
    Then public client input은 public-api.openapi.json이어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-009
  Scenario: TypeScript control client는 control spec만 사용한다
    Given API client generation config가 있다
    Then control client input은 control-api.openapi.json이어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-010
  Scenario: clean client 재생성은 diff가 없다
    Given tracked generated clients가 현재 상태다
    When exact Hey API version으로 다시 생성한다
    Then generated source diff가 없어야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-011
  Scenario: generated 파일 직접 수정은 검출된다
    Given generated source 하나가 수동으로 변경되었다
    When client check를 실행한다
    Then 검사가 실패해야 한다

  # scenario-id: AC-OPENAPI_CODEGEN-012
  Scenario: breaking contract change는 보고 없이 병합되지 않는다
    Given main baseline 대비 breaking schema 또는 operation change가 있다
    When compatibility gate를 실행한다
    Then 승인된 compatibility report가 없으면 실패해야 한다
