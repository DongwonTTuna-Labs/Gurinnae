@hard-gate @final @container
Feature: Docker 개발환경과 runtime image

  # scenario-id: AC-DOCKER_DEVELOPMENT-001
  Scenario: Docker image에 latest tag가 없다
    Given 모든 Compose와 Dockerfile과 image lock이 있다
    Then latest edge canary floating tag가 없어야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-002
  Scenario: DB-only profile은 PostgreSQL만 시작한다
    When infra profile을 시작한다
    Then PostgreSQL이 healthy해야 한다
    And application services는 시작하지 않아야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-003
  Scenario: full profile은 migration 순서를 지킨다
    When full profile을 시작한다
    Then PostgreSQL health 후 migrator가 실행되어야 한다
    And migrator 성공 후에만 APIs와 workers가 시작해야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-004
  Scenario: control API port는 기본 공개되지 않는다
    Given baseline full Compose가 있다
    Then control-api는 host public port mapping을 가지지 않아야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-005
  Scenario: runtime container는 root가 아니다
    Given 각 production runtime image가 있다
    When effective UID를 검사한다
    Then UID 0이 아니어야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-006
  Scenario: image layer에 secret이 없다
    Given built images와 history가 있다
    Then real token password private key가 없어야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-007
  Scenario: test database는 격리된다
    When 두 test runs를 독립 실행한다
    Then 이전 run 데이터와 volume이 다음 run에 보이지 않아야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-008
  Scenario: public API health와 readiness가 구분된다
    Given process는 살아 있으나 migration이 호환되지 않는다
    Then healthz는 process 상태를 나타내고 readyz는 실패해야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-009
  Scenario: full Compose public route가 작동한다
    Given full profile이 healthy하다
    When public-web fixture case route를 요청한다
    Then SSR 200 response와 근거 내용이 있어야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-010
  Scenario: 모든 long-running container가 SIGTERM을 처리한다
    Given APIs workers scheduler web이 실행 중이다
    When Compose stop을 실행한다
    Then configured grace period 안에 정상 종료해야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-011
  Scenario: test Compose는 전체 서비스 토폴로지를 격리한다
    Given standalone compose.test.yaml이 있다
    Then postgres migrator APIs worker scheduler web apps가 test profile에 있어야 한다
    And API host port는 공개되지 않아야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-012
  Scenario: Docker context는 민감한 로컬 상태를 제외한다
    Given .dockerignore가 있다
    Then env key token cookie browser profile node_modules target이 build context에서 제외되어야 한다

# scenario-id: AC-DOCKER_DEVELOPMENT-013
Scenario: PostgreSQL 18은 새 volume root를 사용한다
    Given postgres:18.4-bookworm Compose service가 있다
    Then PGDATA는 /var/lib/postgresql/18/docker여야 한다
    And named volume은 /var/lib/postgresql에 mount되어야 한다
    And /var/lib/postgresql/data 문자열은 없어야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-014
  Scenario: PostgreSQL 18 test tmpfs도 새 root를 사용한다
    Given standalone compose.test.yaml이 있다
    Then postgres tmpfs는 /var/lib/postgresql이어야 한다
    And explicit PGDATA는 production-like path여야 한다

  # scenario-id: AC-DOCKER_DEVELOPMENT-015
  Scenario: PostgreSQL container 재생성 후 데이터가 보존된다
    Given named volume을 사용하는 healthy PostgreSQL 18.4가 있다
    And sentinel row를 commit했다
    When volume은 유지하고 container만 recreate한다
    Then sentinel row가 다시 조회되어야 한다
