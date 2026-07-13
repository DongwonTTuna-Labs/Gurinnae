@hard-gate @final @architecture
Feature: Rust 모노레포와 서비스 경계

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-001
  Scenario: axum dependency는 workspace 어디에도 없다
    Given materialized Cargo workspace가 있다
    When 전체 dependency graph를 검사한다
    Then package 이름 axum은 발견되지 않는다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-002
  Scenario: production Python runtime은 없다
    Given materialized production services와 images가 있다
    When process entrypoint와 runtime dependency를 검사한다
    Then Python service 또는 worker entrypoint가 없어야 한다
    And spec package scripts는 production image에 포함되지 않아야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-003
  Scenario: domain crate는 Actix에 의존하지 않는다
    Given crates/domain의 dependency graph가 있다
    Then actix-web과 actix-http 의존성이 없어야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-004
  Scenario: domain crate는 SQLx에 의존하지 않는다
    Given crates/domain의 dependency graph가 있다
    Then sqlx 의존성이 없어야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-005
  Scenario: domain crate는 Utoipa에 의존하지 않는다
    Given crates/domain의 dependency graph가 있다
    Then utoipa 의존성이 없어야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-006
  Scenario: public API는 editorial write capability를 링크하지 않는다
    Given public-api binary의 reachable dependency graph가 있다
    Then editorial command repository 구현이 reachable하지 않아야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-007
  Scenario: public API DB role은 private schema를 읽지 못한다
    Given gurine_public_api role로 연결한다
    When raw 또는 core 또는 editorial 또는 ops table을 조회한다
    Then PostgreSQL permission error가 발생해야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-008
  Scenario: public API DB role은 public schema를 쓸 수 없다
    Given gurine_public_api role로 연결한다
    When public table에 INSERT 또는 UPDATE를 시도한다
    Then PostgreSQL permission error가 발생해야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-009
  Scenario: public API에는 공개 write operation이 없다
    Given generated public OpenAPI가 있다
    Then health endpoint를 제외한 POST PUT PATCH DELETE operation 수는 0이어야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-010
  Scenario: public web은 control client를 import하지 않는다
    Given public-web의 source와 production bundle이 있다
    Then api-client-control import와 control operation symbol이 없어야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-011
  Scenario: control client는 server-only다
    Given review-console production browser bundle이 있다
    Then control API base URL과 bearer token과 control generated client가 없어야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-012
  Scenario: services는 composition root다
    Given Actix handler와 Tokio runner가 있다
    Then publication policy와 detection calculation은 service crate가 아니라 공유 crate에서 실행되어야 한다

# scenario-id: AC-ARCHITECTURE_BOUNDARIES-013
Scenario: Cargo workspace의 모든 member가 물리적으로 존재한다
    Given blueprint root Cargo.toml이 있다
    Then 각 member path에 Cargo.toml과 src/lib.rs 또는 src/main.rs가 있어야 한다

  # scenario-id: AC-ARCHITECTURE_BOUNDARIES-014
  Scenario: Placeholder implementation marker는 production release를 차단한다
    Given source tree에 REQUIRED_IMPLEMENTATION_PLACEHOLDER marker가 남아 있다
    When final completion 또는 production release gate를 실행한다
    Then 해당 component가 executable acceptance와 교체될 때까지 실패해야 한다
