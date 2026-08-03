@hard-gate @final @public @comprehension
Feature: Public readers understand evidence without being pushed toward an allegation

  Background:
    Given a synthetic publication with a 5.0 price ratio and an unresolved certification-cost question

  # scenario-id: AC-PUBLIC_COMPREHENSION-001
  Scenario: Case detail begins with state and limits
    When a citizen opens the public case
    Then the current status, revision and freshness appear first
    And confirmed facts appear before comparison graphics
    And the most decision-relevant unknown is visible without opening a drawer

  # scenario-id: AC-PUBLIC_COMPREHENSION-002
  Scenario: Price ratio is not presented as corruption probability
    When the comparison metric is rendered
    Then amount, unit, VAT basis, cohort size, date range and exclusions are shown
    And the ratio is not labelled as risk, corruption probability or wrongdoing score

  # scenario-id: AC-PUBLIC_COMPREHENSION-003
  Scenario: No response is described as an observation only
    Given a response request deadline passed without a submission
    When the response section is rendered
    Then it states the request and as-of dates
    And it does not imply admission, guilt or refusal to cooperate

  # scenario-id: AC-PUBLIC_COMPREHENSION-004
  Scenario: Explained and corrected records remain discoverable
    Given one synthetic case is explained and another is corrected
    When the home and case lists are rendered
    Then both states are available alongside anomaly records
    And click volume does not determine ordering

  # scenario-id: AC-PUBLIC_COMPREHENSION-005
  Scenario: Institution and supplier pages avoid rankings
    When an institution or supplier detail page is rendered
    Then counts include denominator, source coverage and freshness
    And no ranking, score, top list or suspicion badge is shown

  # scenario-id: AC-PUBLIC_COMPREHENSION-006
  Scenario: Evidence can be traced from claim to source locator
    When a reader opens a claim evidence view
    Then the source authority, retrieval time, hash and public locator are shown
    And private editorial notes are never exposed

  # scenario-id: AC-PUBLIC_COMPREHENSION-007
  Scenario: Retraction dominates old conclusions
    Given a publication has been retracted for a material unit error
    When any current public route or search result references it
    Then the retraction status and invalidated conclusion appear before historical text

  # scenario-id: AC-PUBLIC_COMPREHENSION-008
  Scenario: Empty results do not imply integrity
    When public filters return no published records
    Then the empty state explains the selected scope and coverage
    And it does not describe the institution or supplier as clean or problem-free
