@hard-gate @final @analytics @privacy
Feature: Product analytics measure task quality without collecting sensitive investigation content

  # scenario-id: AC-ANALYTICS_PRIVACY-001
  Scenario: Audit logs and analytics are separate records
    When a high-impact command occurs
    Then its authoritative audit event is written independently of product analytics
    And analytics outage cannot prevent the command receipt

  # scenario-id: AC-ANALYTICS_PRIVACY-002
  Scenario: Response content is never an analytics property
    When a response party types, saves, uploads or submits
    Then answer body, attachment filename, token and contact details are absent from analytics

  # scenario-id: AC-ANALYTICS_PRIVACY-003
  Scenario: Correction content is never an analytics property
    When a correction requester submits an error description
    Then correction body, evidence URL and contact details are absent from analytics

  # scenario-id: AC-ANALYTICS_PRIVACY-004
  Scenario: Public search text is minimized
    When a visitor performs public search
    Then raw query text is not sent to product analytics
    And only approved query-length, result-count and object-type buckets may be recorded

  # scenario-id: AC-ANALYTICS_PRIVACY-005
  Scenario: SSR and browser do not double-count a page view
    When a SvelteKit route is server-rendered and hydrated
    Then one logical view event is emitted according to the approved event ownership rule

  # scenario-id: AC-ANALYTICS_PRIVACY-006
  Scenario: Every event has purpose and consumer
    When analytics-events.yaml is validated
    Then every event has purpose, allowed properties, forbidden properties, retention and consuming screens

  # scenario-id: AC-ANALYTICS_PRIVACY-007
  Scenario: Response Portal has zero third-party collection
    When the Response Portal bundle and network requests are inspected
    Then no third-party analytics endpoint or session replay library is present

  # scenario-id: AC-ANALYTICS_PRIVACY-008
  Scenario: Analytics failure is nonblocking
    When the analytics collector is unavailable
    Then public reading, response submission and internal safety commands continue
    And no retry queue stores prohibited payload data
