@hard-gate @final @operations @production
Feature: Production deployment is operable and recoverable

  # scenario-id: AC-PRODUCTION_READINESS-001
  Scenario: Clean database deployment is deterministic
    Given an empty PostgreSQL 18.4 database
    When the migrator runs
    Then all migrations and grants succeed against PostgreSQL 18.4
    And every GRANT ON FUNCTION resolves to an existing pg_proc signature
    And extension objects live in the non-public extensions schema
    And every SECURITY DEFINER search_path contains only trusted schemas and ends in pg_temp
    And the audit append canary, single-response-submission canary and negative privilege canaries pass
    And every service role has only its declared privileges

  # scenario-id: AC-PRODUCTION_READINESS-002
  Scenario: Restart preserves durable state
    Given a fully healthy production-like Compose stack
    When all application containers are recreated
    Then PostgreSQL and object-store state remain
    And unfinished jobs resume under lease and fencing rules
    And duplicate publication does not occur

  # scenario-id: AC-PRODUCTION_READINESS-003
  Scenario: Backup restore is rehearsed
    Given encrypted database and object-store backups
    When a clean restore environment is created
    Then public and private records are restored
    And audit-chain and object hashes verify
    And the recovery time and recovery point objectives are recorded

  # scenario-id: AC-PRODUCTION_READINESS-004
  Scenario: Graceful shutdown protects work
    Given API requests and worker jobs are in progress
    When SIGTERM is delivered
    Then traffic readiness is removed
    And bounded work completes or returns safely to the queue
    And no lock or lease remains indefinitely

  # scenario-id: AC-PRODUCTION_READINESS-005
  Scenario: Service health distinguishes dependency failure
    Given PostgreSQL, OIDC, SMTP, object storage or a source is unavailable
    Then readiness reports the affected capability without exposing credentials
    And liveness does not restart a healthy process solely for an external outage

  # scenario-id: AC-PRODUCTION_READINESS-006
  Scenario: PostgreSQL runtime verification leaves the source tree byte-identical
    Given specs/ is the active specification tree and authority-v13-frozen is the frozen base anchor
    When make verify-postgres-runtime is executed
    Then dynamic UUIDs and hashes are written only to an external temporary file
    And the stable baseline comparator passes
    And the Git-bound source tree digest is identical before and after verification
    And make verify-specs and make verify-codegen still pass
