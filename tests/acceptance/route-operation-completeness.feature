@hard-gate @final @routes @contract
Feature: Every final screen and operation is implemented exactly once

  # scenario-id: AC-ROUTE_OPERATION_COMPLETENESS-001
  Scenario: All 94 screen routes render
    Given the three web applications are running with synthetic data
    When the route crawler visits the screen catalog
    Then 34 public, 8 response and 52 internal screens resolve
    And no route renders a generic placeholder or 501 state

  # scenario-id: AC-ROUTE_OPERATION_COMPLETENESS-002
  Scenario: All HTTP operations are exposed exactly once
    Given the three APIs are running
    When their generated OpenAPI documents are collected
    Then 42 public, 125 control and 22 submission operations exist
    And operationIds are globally unique
    And every handler conforms to its request and response schema

  # scenario-id: AC-ROUTE_OPERATION_COMPLETENESS-003
  Scenario: Identity flows are implemented
    Given the internal application is configured with the test OIDC provider
    Then login and recent step-up authentication complete
    And safe return URLs, state, nonce and PKCE are validated

  # scenario-id: AC-ROUTE_OPERATION_COMPLETENESS-004
  Scenario: Screen and operation traceability is complete
    Given any screen data requirement
    Then its generated client method exists
    And a server handler and integration test exist
    And a Playwright test covers the consuming screen state
