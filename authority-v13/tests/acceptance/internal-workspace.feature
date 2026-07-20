@hard-gate @final @internal-workspace
Feature: Internal workspaces support explicit decisions and evidence rather than generic CRUD

  # scenario-id: AC-INTERNAL_WORKSPACE-001
  Scenario: Signal triage shows deterministic information before AI suggestions
    When a triager opens a signal
    Then rule inputs, calculation, cohort, blockers, freshness and identity quality appear first
    And AI suggestions appear in a subordinate labelled region

  # scenario-id: AC-INTERNAL_WORKSPACE-002
  Scenario: Triage decision records a bounded disposition
    When a triager promotes, dismisses, links or requests data for a signal
    Then a reason code, explanation and expected version are required
    And the action produces an audit receipt

  # scenario-id: AC-INTERNAL_WORKSPACE-003
  Scenario: Case overview exposes next task and blockers
    When an investigator opens a case workspace
    Then current state, owner, next task, critical unknowns and gate status are visible
    And the investigator is not forced to infer workflow from entity tabs

  # scenario-id: AC-INTERNAL_WORKSPACE-004
  Scenario: Concurrent save preserves the local draft
    Given the investigator edits case version 12
    And another actor commits version 13
    When the investigator saves with expected version 12
    Then the server rejects the write as a conflict
    And the local draft and server diff remain available

  # scenario-id: AC-INTERNAL_WORKSPACE-005
  Scenario: Agent output cannot become machine truth automatically
    When a bounded agent run returns suggestions
    Then each suggestion includes input snapshot, model, prompt version, citations and validation status
    And a human must accept or reject each proposed record with a reason

  # scenario-id: AC-INTERNAL_WORKSPACE-006
  Scenario: Independent review enforces separation of duties
    Given an investigator authored a material claim
    When the same actor attempts to approve the exact review snapshot
    Then approval is denied
    And the conflict reason is shown without suggesting a UI workaround

  # scenario-id: AC-INTERNAL_WORKSPACE-007
  Scenario: Stale approval cannot publish changed content
    Given a snapshot was approved
    And claim or evidence content changed afterward
    When a publisher opens publication confirmation
    Then the previous approval is marked stale
    And publication is blocked until a new snapshot and approval exist

  # scenario-id: AC-INTERNAL_WORKSPACE-008
  Scenario: High-impact operation always shows a receipt
    When a rule activation, source pause, kill switch, role grant or publication succeeds
    Then exact target, actor, reason, policy version, timestamp and request identifier are shown
