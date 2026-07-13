@hard-gate @final @database
Feature: PostgreSQL 18.4와 SQLx 안전성

  # scenario-id: AC-SQLX_POSTGRES-001
  Scenario: 정확한 PostgreSQL 버전에서 migration한다
    Given postgres:18.4-bookworm test service가 healthy하다
    When clean database에 migrations를 실행한다
    Then 모든 migration이 성공해야 한다
    And server_version은 18.4여야 한다

  # scenario-id: AC-SQLX_POSTGRES-002
  Scenario: API startup은 migration을 실행하지 않는다
    Given migration이 적용되지 않은 database가 있다
    When public-api 또는 control-api를 시작한다
    Then service는 readiness에 실패해야 한다
    And schema를 자동 변경하지 않아야 한다

  # scenario-id: AC-SQLX_POSTGRES-003
  Scenario: one-shot migrator 실패는 서비스 시작을 막는다
    Given migrator가 non-zero로 종료한다
    When full Compose를 시작한다
    Then dependent application service는 시작하지 않아야 한다

  # scenario-id: AC-SQLX_POSTGRES-004
  Scenario: SQLx offline build가 성공한다
    Given current .sqlx metadata가 있다
    And DATABASE_URL이 없다
    When SQLX_OFFLINE=true cargo check를 실행한다
    Then workspace check가 성공해야 한다

  # scenario-id: AC-SQLX_POSTGRES-005
  Scenario: stale SQLx metadata는 실패한다
    Given query 또는 migration이 바뀌었지만 .sqlx가 갱신되지 않았다
    When cargo sqlx prepare --workspace --check를 실행한다
    Then 검사가 실패해야 한다

  # scenario-id: AC-SQLX_POSTGRES-006
  Scenario: optimistic concurrency가 stale write를 거부한다
    Given case version이 7이다
    When expected_version 6으로 transition command를 실행한다
    Then aggregate version conflict가 발생해야 한다
    And 상태가 바뀌지 않아야 한다

  # scenario-id: AC-SQLX_POSTGRES-007
  Scenario: idempotency key 재생은 같은 결과를 돌려준다
    Given 동일 principal operation key와 동일 payload hash가 있다
    When command를 다시 보낸다
    Then 최초 결과가 재생되어야 한다
    And 추가 domain event가 없어야 한다

  # scenario-id: AC-SQLX_POSTGRES-008
  Scenario: idempotency key payload 충돌은 거부한다
    Given 동일 principal operation key가 다른 payload hash로 재사용된다
    Then idempotency conflict가 발생해야 한다

  # scenario-id: AC-SQLX_POSTGRES-009
  Scenario: domain mutation과 outbox는 원자적이다
    Given publication command transaction이 있다
    When outbox insert가 실패한다
    Then publication revision도 commit되지 않아야 한다

  # scenario-id: AC-SQLX_POSTGRES-010
  Scenario: 잃어버린 lease worker는 완료를 기록하지 못한다
    Given worker A의 lease가 만료되고 worker B가 새 fencing token을 얻었다
    When worker A가 완료 write를 시도한다
    Then write는 거부되어야 한다

  # scenario-id: AC-SQLX_POSTGRES-011
  Scenario: duplicate outbox delivery는 한 번만 적용된다
    Given 같은 event ID가 consumer에 두 번 전달된다
    Then inbox dedupe로 public projection은 한 번만 변경되어야 한다

  # scenario-id: AC-SQLX_POSTGRES-012
  Scenario: 금액은 부동소수점으로 저장되지 않는다
    Given money 관련 SQL schema와 Rust types가 있다
    Then f32 또는 f64 기반 금액 필드가 없어야 한다
    And KRW 금액은 integer minor unit 또는 승인된 lossless decimal이어야 한다

# scenario-id: AC-SQLX_POSTGRES-013
Scenario: PostgreSQL 18 container path 계약이 machine spec과 일치한다
    Given technology baseline container matrix와 Compose가 있다
    Then image volume mount와 PGDATA 값이 모두 같아야 한다

  # scenario-id: AC-SQLX_POSTGRES-014
  Scenario: SQLx CLI install exception은 query 검증을 약화하지 않는다
    Given SQLx CLI가 upstream lock exception으로 설치되었다
    When current PostgreSQL 18.4 schema에서 prepare check와 offline build를 실행한다
    Then 두 검사는 기존 strict gate를 그대로 통과해야 한다
