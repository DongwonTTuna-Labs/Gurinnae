@hard-gate @final @accessibility @responsive
Feature: Core tasks remain complete with keyboard, assistive technology and compact layouts

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-001
  Scenario: Heading and landmark order follows the information hierarchy
    When a public case is navigated by headings and landmarks
    Then status, known facts, unknowns, response, comparison and evidence occur in a meaningful order
    And visual rearrangement does not change the programmatic reading order

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-002
  Scenario: Keyboard users can operate drawers and dialogs
    When an evidence drawer or confirmation dialog opens from the keyboard
    Then focus moves to its labelled heading
    And focus remains within a modal dialog when appropriate
    And closing returns focus to the invoking control

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-003
  Scenario: Form errors provide summary and field association
    When a response or correction form is submitted with invalid fields
    Then focus moves to an error summary
    And each error links to a labelled field with preserved input
    And color is not the only error indicator

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-004
  Scenario: Data visualization has an equivalent table or text
    When a distribution or trend chart is rendered
    Then its conclusion, units, cohort and exclusions are available without perceiving color or shape
    And the underlying accessible table is reachable

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-005
  Scenario: Two hundred percent zoom preserves core task completion
    When the viewport is zoomed to 200 percent
    Then no required content or action is clipped in two dimensions
    And fixed headers do not obscure focused controls

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-006
  Scenario: Compact layout preserves primary information
    When a screen uses the compact responsive profile
    Then primary job, status, critical unknown and primary action remain present
    And secondary context may move to a drawer but is not deleted

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-007
  Scenario: Dynamic status announcements are restrained
    When source freshness or upload state updates automatically
    Then only task-relevant state changes use an appropriate live region
    And repeated background refreshes do not interrupt screen-reader users

  # scenario-id: AC-ACCESSIBILITY_RESPONSIVE-008
  Scenario: Reduced motion preference is respected
    Given the user requests reduced motion
    When drawers, route transitions or charts update
    Then nonessential animation is removed and no information depends on motion
