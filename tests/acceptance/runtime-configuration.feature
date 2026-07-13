@hard-gate @final @configuration @security
Feature: Runtime configuration and secrets are complete and safe

  # scenario-id: AC-RUNTIME_CONFIGURATION-001
  Scenario: Every runtime variable is cataloged
    Given an environment variable is read by production code
    Then it exists in secret-and-key-catalog.yaml
    And its required condition, service scope, secrecy and startup behavior are defined

  # scenario-id: AC-RUNTIME_CONFIGURATION-002
  Scenario: Production rejects placeholder secrets
    Given a production environment contains REPLACE, LOCAL_ONLY or a default password
    When production-preflight runs
    Then startup is rejected before network service readiness

  # scenario-id: AC-RUNTIME_CONFIGURATION-003
  Scenario: Missing source key is isolated
    Given one optional source credential is absent
    When production-preflight runs
    Then that source is disabled with an operational reason
    And unrelated sources and deterministic processing remain available

  # scenario-id: AC-RUNTIME_CONFIGURATION-004
  Scenario: Missing foundational crypto key is fatal
    Given a session, field-encryption, token-HMAC or audit-chain key is absent
    When a service starts in production
    Then it exits non-zero without accepting traffic

  # scenario-id: AC-RUNTIME_CONFIGURATION-005
  Scenario: Secrets never reach logs or public diagnostics
    Given any service emits logs, metrics, traces or problem responses
    Then secret values, tokens, response text and private attachment names are redacted
