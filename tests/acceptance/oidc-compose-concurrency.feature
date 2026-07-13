@hard-gate @final @oidc @compose @concurrency
Feature: Final authentication, runtime configuration and optimistic concurrency closure

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-001
  Scenario: Anonymous login start creates the transaction it later consumes
    Given an anonymous browser and an allowlisted returnTo path
    When startOidcLogin is invoked
    Then no prior OIDC session or transaction cookie is required
    And a LOGIN state, nonce and PKCE transaction is persisted
    And the browser is redirected to the configured issuer

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-002
  Scenario: Login callback consumes a single-use transaction
    Given an unexpired LOGIN transaction cookie
    When completeOidcCallback receives matching code and state
    Then state, issuer, nonce and PKCE are verified
    And the transaction is consumed exactly once
    And an opaque internal session is created
    And a 256-bit synchronizer CSRF token is generated
    And only its hash is stored in ops.sessions
    And the BFF calls the private Identity API with a method/path/query/body-bound single-use service assertion
    And the BFF seals the opaque session token and plaintext CSRF token into a host-only HttpOnly cookie with Path=/

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-003
  Scenario: Step-up start is bound to the current session and action
    Given an active internal session, valid CSRF token and typed STEP_UP action descriptor
    When startStepUpAuthentication is invoked
    Then the BFF generates an Idempotency-Key and canonical action digest
    And a STEP_UP transaction bound to the session, action context, digest and Idempotency-Key hash is created
    And the raw Idempotency-Key is preserved only in the encrypted transaction cookie
    And the IdP redirect requests the configured max_age or acr

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-004
  Scenario: Step-up callback issues a bounded action authorization
    Given the same active session and a matching STEP_UP transaction cookie
    When completeStepUpAuthentication receives the matching callback
    Then the transaction is consumed once
    And a five-minute authorization bound to the exact action digest and Idempotency-Key is issued in a host-only encrypted SameSite=Strict cookie with Path=/internal
    And that authorization may issue at most three fresh single-use Actor Assertions
    And the synchronizer CSRF token is rotated and the internal session cookie is resealed
    And the callback itself returns no Actor Assertion
    And the BFF later requests a short-lived Actor Assertion bound to method, path, query digest, body digest, audience, session and action digest
    And the Control API accepts only that actor assertion and never receives browser session or CSRF cookies
    And service-assertion replay, actor-assertion replay, a stale CSRF token or a different session is rejected

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-005
  Scenario: Development Compose passes every scoped runtime variable
    Given .env.example and compose-reference.yaml
    When the service config map is validated
    Then every cataloged first-party service variable is explicitly forwarded
    And filesystem object storage and file email outbox volumes are mounted to their declared services

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-006
  Scenario: Every versioned command uses the exact expected-version predicate
    Given a command whose request contains expectedVersion or expectedCaseVersion
    Then command semantics, persistence, table matrix and traceability contain the same concurrency contract
    And every guard and mutation relation and predicate column resolves in PostgreSQL pg_catalog
    And schema mapping uses schema_drifts.id plus the exact mapping version and digest
    And queue/source controls use queue_name/source_id rather than invented id columns
    And the guard predicate uses the declared version field
    And direct table mutations increment the version exactly once or delete the exact current version
    And SECURITY DEFINER procedure-backed commands name the actual guard table, function signature and internal mutation relations
    And submitResponse guards the draft version while atomically inserting one immutable submission, terminalizing the request and revoking the token

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-007
  Scenario: Session resolution never issues a request-unbound Actor Assertion
    Given a valid sealed internal session cookie
    When the BFF resolves the session through the private Identity API
    Then the response contains actor identity and session state only
    And no Actor Assertion is issued until the exact downstream Control request is known

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-008
  Scenario: Every Control request receives an exact request-bound Actor Assertion
    Given an authenticated BFF request to a Control API operation
    When the BFF computes method, normalized path, canonical query hash, exact body hash, content type, operation ID, capability and Idempotency-Key hash
    Then issueActorAssertion validates the active session and capability
    And the Actor Assertion contains the exact downstream binding
    And Control API rejects any method, path, query, body, content type, operation, capability or Idempotency-Key mismatch

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-009
  Scenario: A STEP_UP command can be retried safely after a lost response
    Given a completed step-up ceremony bound to one action digest and Idempotency-Key hash
    When the BFF loses the first Control response
    Then the Identity API may issue a fresh Actor Assertion JTI for the same exact binding
    And no more than three assertions are issued during the five-minute authorization
    And the BFF reuses the same Idempotency-Key and exact request bytes
    And the Control API returns the original idempotent receipt without a duplicate mutation
    And the authorization is closed after a terminal receipt or expires automatically

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-010
  Scenario: Raw step-up authorization never crosses the Control API boundary
    Given a Control command whose assurance level is STEP_UP
    Then its request schema contains no reauthProof or step-up token field
    And gurine_control_api has no execute privilege on step-up authorization claim or close functions
    And only gurine_identity_api may claim or close the authorization


  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-011
  Scenario: Internal session cookie has one canonical opaque-token payload
    Given the Review Console BFF receives a successful login callback
    When gurine_internal_session is sealed
    Then its payload contains only v, typ, opaqueIdentitySessionToken, csrfToken, issuedAt, absoluteExpiresAt and csrfRotatedAt
    And Identity API session resolution receives opaqueSessionToken rather than an encrypted browser cookie
    And sessionId or userId in browser state is never authoritative

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-012
  Scenario: Interaction confirmation and authentication assurance are separate contracts
    Given any screen action
    Then interactionKind describes navigation, form submission, command or destructive confirmation
    And assuranceLevel independently declares NONE, ANONYMOUS_PROOF, SCOPED_TOKEN, ACTIVE_SESSION, RECENT_SESSION or STEP_UP
    And command semantics is the security assurance authority
    And every operation-linked action matches the evaluated command assurance

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-013
  Scenario: Legal hold uses a dedicated step-up command
    Given an exact immutable review snapshot and case version
    When placeLegalHold is submitted with scope, reason, authority reference and optional expiry
    Then the case version advances exactly once
    And one active legal hold is linked to the case, snapshot and target object
    And submitReview is not overloaded to represent a legal hold

  # scenario-id: AC-OIDC_COMPOSE_CONCURRENCY-014
  Scenario: Audit export is an asynchronous audited step-up command
    Given a bounded time range, typed scope, reason, watermark policy and expiry
    When createAuditExport is submitted after step-up
    Then an immutable audit export request and one deduplicated workflow job are committed
    And audit.export_requested.v1 is emitted through the outbox
    And the caller receives an accepted receipt rather than synchronous private bytes
