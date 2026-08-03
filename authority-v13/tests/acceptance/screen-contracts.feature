@hard-gate @final @screen-contracts
Feature: Every screen is governed by a final product and implementation contract

  # scenario-id: AC-SCREEN_CONTRACTS-001
  Scenario: Screen inventory has unique stable identifiers and routes
    When screen-catalog.yaml is validated
    Then exactly 94 unique screen identifiers exist
    And Public Web has 34 screens
    And Response Portal has 8 screens
    And Review Console has 52 screens
    And no route is duplicated within a surface

  # scenario-id: AC-SCREEN_CONTRACTS-002
  Scenario: Every screen is required in the single final delivery
    Given any screen in the catalog
    Then release_scope is FINAL
    And implementation_status is REQUIRED_COMPLETE
    And visual_status is FINAL
    And no milestone or deferred implementation field exists

  # scenario-id: AC-SCREEN_CONTRACTS-003
  Scenario: A screen answers a user job before listing UI components
    Given any screen in the catalog
    Then it defines primary users, a primary job and user questions
    And it defines an exact above-fold order
    And it defines ordered information sections before implementation details

  # scenario-id: AC-SCREEN_CONTRACTS-004
  Scenario: Every screen data dependency is final and ready
    Given any screen data requirement
    Then its status is READY
    And its operationId exists in operation-contracts.yaml
    And exact API, method, path, request schema and response schema are known
    And a mock success response is not an acceptable substitute

  # scenario-id: AC-SCREEN_CONTRACTS-005
  Scenario: Operation exists on exactly the matching API
    Given an operation is assigned to submission-api
    Then the same operationId exists in submission-api.openapi.yaml
    And it does not exist in public-api.openapi.yaml
    And it does not exist in control-api.openapi.yaml

  # scenario-id: AC-SCREEN_CONTRACTS-006
  Scenario: Every screen has a final human-readable sheet
    When screen-catalog.yaml is compared with specs/ui/screens
    Then exactly 94 screen sheets exist
    And every sheet has route, user job, section order, layout, action, data, states, accessibility and acceptance
    And no milestone-era nested screen sheet exists

  # scenario-id: AC-SCREEN_CONTRACTS-007
  Scenario: Screen actions require known capabilities and guards
    Given a screen action mutates state
    Then its capability exists in roles-and-permissions.yaml
    And its command operation is defined
    And authorization is re-evaluated by the server
    And every action enforces its declared interaction kind and assurance level

  # scenario-id: AC-SCREEN_CONTRACTS-008
  Scenario: Every declared component is final
    Given a section references a component
    Then that component exists in component-catalog.yaml
    And the component defines anatomy, variants, states, accessibility and implementation requirements

  # scenario-id: AC-SCREEN_CONTRACTS-009
  Scenario: Every analytics event is bidirectionally mapped
    Given a screen declares an analytics event
    Then the event exists in analytics-events.yaml
    And the event lists or accepts the consuming screen
    And forbidden personal or response content cannot enter the payload

  # scenario-id: AC-SCREEN_CONTRACTS-010
  Scenario: Compact layout preserves semantic order
    Given any screen with a compact layout
    When it is rendered at 320 CSS pixels
    Then the section order remains semantically identical
    And all critical actions are reachable
    And no primary task depends only on horizontal scrolling
