@hard-gate @final @product-structure
Feature: Product surfaces and information architecture remain separated

  Background:
    Given the approved v3 screen catalog contains only synthetic example data

  # scenario-id: AC-PRODUCT_STRUCTURE-001
  Scenario: Public Web is anonymous-read by default
    When an anonymous visitor opens a public publication route
    Then the visitor can read the approved public projection without creating an account
    And no internal session or control client is initialized

  # scenario-id: AC-PRODUCT_STRUCTURE-002
  Scenario: Review Console requires the internal identity boundary
    When a browser without an approved OIDC session opens an internal route
    Then the route does not reveal the private object title or existence
    And the user is sent through the approved identity flow

  # scenario-id: AC-PRODUCT_STRUCTURE-003
  Scenario: Response Portal uses a distinct token-scoped surface
    Given a valid synthetic response request token
    When the response party opens the request
    Then the request is rendered by Response Portal
    And Review Console navigation and internal session controls are absent

  # scenario-id: AC-PRODUCT_STRUCTURE-004
  Scenario: Surface navigation follows user jobs rather than database tables
    When the product navigation is rendered
    Then Public Web exposes discovery, methodology, correction, status and transparency groups
    And Review Console exposes triage, investigation, review, data, rules, operations and administration groups
    And Response Portal exposes only the current submission steps and safety/help links

  # scenario-id: AC-PRODUCT_STRUCTURE-005
  Scenario: Combined application deployment is rejected
    When an implementation places Public Web, Review Console and Response Portal in one SvelteKit app
    Then the architecture fitness gate fails

  # scenario-id: AC-PRODUCT_STRUCTURE-006
  Scenario: Combined API client generation is rejected
    When internal, public and submission operations are generated into one client package
    Then the architecture fitness gate fails

  # scenario-id: AC-PRODUCT_STRUCTURE-007
  Scenario: Unknown routes are not invented by implementation
    Given a proposed route is absent from screen-catalog.yaml and an approved redirect
    When Codex attempts to scaffold that route
    Then final product specification validation fails

  # scenario-id: AC-PRODUCT_STRUCTURE-008
  Scenario: Product hierarchy cannot be changed for visual convenience
    Given the public case detail section order is approved
    When an implementation places a price-ratio chart before status, known facts and critical unknowns
    Then the product structure acceptance fails
