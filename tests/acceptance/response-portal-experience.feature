@hard-gate @final @response-portal
Feature: Response parties can safely understand, draft and submit a response

  Background:
    Given all response examples use a synthetic organization and synthetic request

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-001
  Scenario: Opening a valid token shows the exact request scope
    Given a valid unexpired response token
    When the response party opens the portal
    Then the target organization, questions, deadline, source links and privacy notice are visible
    And unpublished internal hypotheses are not exposed

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-002
  Scenario: Token is exchanged and removed from the visible URL
    Given a valid response token in the initial URL
    When the server establishes the scoped response session
    Then subsequent browser navigation does not contain the raw token
    And the token is absent from browser storage, logs and analytics

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-003
  Scenario: Draft is not mistaken for submission
    When a response party saves a draft
    Then the portal displays a draft status and last saved time
    And no receipt or submitted status is issued
    And publication state is unchanged

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-004
  Scenario: Attachment remains quarantined until validation succeeds
    When an attachment upload completes
    Then the UI distinguishes upload completion from scan and validation completion
    And an unsafe or unsupported file cannot be submitted as verified evidence

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-005
  Scenario: Public-use consent is granular and independent
    When the response party reviews submission
    Then full, redacted, summary-only and no-consent/legal-review choices are explained
    And declining public-use consent does not block intake for editorial review

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-006
  Scenario: Final submission produces an immutable receipt
    When a valid response is submitted with an idempotency key
    Then the portal shows submission identifier and accepted timestamp
    And repeated submission with the same key does not create a duplicate
    And sensitive body content is not emailed back

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-007
  Scenario: Expired or invalid token reveals no case details
    Given a missing, expired or revoked token
    When the portal is opened
    Then a generic recovery path is shown
    And case title, questions and party details are not disclosed

  # scenario-id: AC-RESPONSE_PORTAL_EXPERIENCE-008
  Scenario: Third-party analytics and chat are absent
    When any Response Portal page loads
    Then no third-party analytics, advertising pixel, chat widget or session replay script is requested
