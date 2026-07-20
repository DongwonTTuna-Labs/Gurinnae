@hard-gate @final @release
Feature: The delivered artifact is a complete one-shot product

  # scenario-id: AC-FINAL_DELIVERY-001
  Scenario: No required capability is deferred
    Given the final source archive is extracted cleanly
    Then no required screen, operation, service, database table or test is marked deferred
    And no TODO, TBD, 501, unimplemented marker or placeholder implementation exists

  # scenario-id: AC-FINAL_DELIVERY-002
  Scenario: All products are present
    Then public-web, review-console and response-portal build and start
    And public-api, control-api and submission-api build and start
    And ingest, analysis, projection, notification and workflow workers build and start
    And document extractor, scheduler and migrator build and start in their declared modes

  # scenario-id: AC-FINAL_DELIVERY-003
  Scenario: Development works without external provider keys
    Given only .env.example local values are present
    When docker compose up --build is run
    Then synthetic data is loaded
    And all three web applications become healthy
    And every critical user journey can be exercised without external network access

  # scenario-id: AC-FINAL_DELIVERY-004
  Scenario: Production requires only documented deployment inputs
    Given a valid production environment matching the secret catalog
    When production-preflight succeeds
    Then the same application images start with live adapters
    And no source code or generated client change is required

  # scenario-id: AC-FINAL_DELIVERY-005
  Scenario: Partial success cannot be reported as complete
    Given any hard gate fails
    Then the final verdict is CHANGES_REQUIRED
    And the exact failed command and missing capability are reported
