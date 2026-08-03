@hard-gate @final @security @submission-boundary
Feature: External intake is isolated behind BFF assertions and scoped sessions

  # scenario-id: AC-SUBMISSION_BOUNDARY-001
  Scenario: Browser cannot call Submission API directly
    When a public or response browser performs a submission task
    Then the request is sent to a same-origin SvelteKit server action
    And the server-only client signs a request-bound service assertion

  # scenario-id: AC-SUBMISSION_BOUNDARY-002
  Scenario: Every Submission OpenAPI security requirement resolves
    When the Submission OpenAPI document is validated
    Then every security requirement names BffServiceAssertion or ScopedSubmissionSession
    And no undefined or unused submission security scheme remains

  # scenario-id: AC-SUBMISSION_BOUNDARY-003
  Scenario: Raw bearer tokens never enter Submission API URLs
    When response, receipt, verification or management magic links are opened
    Then only the BFF exchange route sees the one-time token
    And every Submission API path and query is token-free

  # scenario-id: AC-SUBMISSION_BOUNDARY-004
  Scenario: Response magic token becomes a pending scoped session
    Given an unused unexpired response magic token
    When the Response Portal BFF exchanges it once
    Then the raw token is consumed
    And a RESPONSE_PENDING opaque session is sealed in a host-only cookie
    And the browser is redirected to a token-free canonical URL

  # scenario-id: AC-SUBMISSION_BOUNDARY-005
  Scenario: OTP promotes response access by rotating the session
    Given a valid RESPONSE_PENDING session
    When the email OTP succeeds
    Then the pending session is consumed
    And a new RESPONSE_ACTIVE session is issued for exactly one response request

  # scenario-id: AC-SUBMISSION_BOUNDARY-006
  Scenario: Response submission terminalizes the active session
    Given a clean finalized response draft at the expected version
    When submitResponse succeeds
    Then exactly one immutable response submission is created
    And the active response session is consumed
    And a read-only RESPONSE_RECEIPT session is issued

  # scenario-id: AC-SUBMISSION_BOUNDARY-007
  Scenario: Correction draft supports upload preview and atomic submit
    Given a scoped CORRECTION_DRAFT session
    When the requester saves fields, uploads and finalizes clean attachments, previews and submits
    Then the draft version is checked
    And the immutable correction request and attachments are created atomically
    And the draft session is consumed
    And a CORRECTION_RECEIPT session is issued

  # scenario-id: AC-SUBMISSION_BOUNDARY-008
  Scenario: Subscription creation is anonymous but abuse controlled
    When a visitor creates a subscription
    Then no pre-existing scoped token is required
    And same-origin CSRF, rate limiting and abuse proof are required
    And the verification token is delivered out of band

  # scenario-id: AC-SUBMISSION_BOUNDARY-009
  Scenario: Verification and management links create scoped subscription sessions
    Given an unused verification or management token
    When the Public Web BFF exchanges it
    Then the token is consumed
    And a SUBSCRIPTION_MANAGEMENT session is issued
    And management routes contain no token

  # scenario-id: AC-SUBMISSION_BOUNDARY-010
  Scenario: Contact and export creation are BFF asserted and abuse controlled
    When an anonymous contact or dataset export request is submitted
    Then a request-bound BFF assertion and abuse proof are verified
    And no fictional pre-existing user token is required

  # scenario-id: AC-SUBMISSION_BOUNDARY-011
  Scenario: Scoped sessions cannot cross records or kinds
    Given a valid scoped session for one object
    When it is used for another scope ID or another session kind
    Then Submission API rejects it without revealing the target object

  # scenario-id: AC-SUBMISSION_BOUNDARY-012
  Scenario: Submission API role cannot mutate investigation or publication state
    Given a connection as gurine_submission_api
    When it attempts to access raw, core, private investigation or publication state
    Then PostgreSQL denies access

  # scenario-id: AC-SUBMISSION_BOUNDARY-013
  Scenario: Submission logs redact every credential
    When exchange, upload, validation or submission events are logged
    Then raw magic token, scoped session token, body, contact email and original filename are absent
    And only a safe request identifier supports incident correlation

  # scenario-id: AC-SUBMISSION_BOUNDARY-014
  Scenario: BFF service assertions are request bound and single use
    Given public-web or response-portal calls Submission API
    Then issuer, audience, method, path, query, body, content type and idempotency digest are signed
    And replay, wrong audience and request mismatch are rejected

  # scenario-id: AC-SUBMISSION_BOUNDARY-015
  Scenario: Browser session cookies are encrypted and CSRF protected
    Given a scoped submission session
    Then the opaque token is present only in an authenticated-encrypted host-only HttpOnly cookie
    And every browser state change requires a rotated synchronizer CSRF token
