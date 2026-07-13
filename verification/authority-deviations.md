# Authority deviations

The v13 authority package is the only product specification. When an exact
dependency statement cannot resolve against the cited released artifacts, the
smallest compatible deviation is recorded here and is covered by the complete
verification suite.

## `subtle` 2.6.0 yanked from new resolution

- Authority intent: exact 2.6.0 and constant-time explicit secret comparison.
- Current evidence: crates.io refuses a fresh resolution because 2.6.0 is
  yanked.
- Resolution: vendor the exact published 2.6.0 crate, SHA-256
  `0d0208408ba0c3df17ed26eb06992cb1a1268d41b2c0e12e65203fbe3972cee5`,
  and patch crates.io to the local immutable source.

## `thiserror` 2.0.16 conflicts with SQLx 0.9.0

- Authority intent: SQLx 0.9.0 is the database contract; `thiserror` is an
  internal error-derivation dependency.
- Current evidence: the published `sqlx-core 0.9.0` requires
  `thiserror ^2.0.18`, which Cargo cannot unify with exact 2.0.16.
- Resolution: retain SQLx 0.9.0 and select exact `thiserror 2.0.18`. This has no
  wire, persistence, authorization, or business-rule contract effect.

## `time` 0.3.41 conflicts with SQLx 0.9.0

- Authority intent: SQLx 0.9.0 and stable timestamp semantics.
- Current evidence: the published `sqlx-core 0.9.0` requires `time ^0.3.47`.
- Resolution: select the lowest compatible release, exact `time 0.3.47`, and
  retain the authority-requested serde, formatting, and parsing features.

## `serde` 1.0.219 conflicts with the compatible `time` and parser floors

- Current evidence: `time 0.3.47` uses `serde_core ^1.0.220` and an exact
  matching `serde_derive`, which cannot coexist with exact serde 1.0.219.
- Current parser evidence: authority-pinned `csv 1.4.0` requires
  `serde_core ^1.0.221`.
- Resolution: select the lowest version satisfying both floors, exact
  `serde 1.0.221`.

## `estimateBackfillReceipt` has an unsatisfiable recursive required field

- Current evidence: the authority schema requires `data` and defines it as an
  unbounded self-reference to `estimateBackfillReceipt`; no finite JSON value
  can conform.
- Corroborating contract: screen `SRC-006` requires a bounded estimate of
  records, jobs, cost, duration, deduplication, and downstream effects.
- Resolution: preserve `specs/api` unchanged and deterministically correct the
  runtime artifact in `specs/generated/control-api.openapi.json` by introducing
  `BackfillEstimate` with those concrete fields.

## Checked-in generated Submission OpenAPI omits seven final operations

- Current evidence: `specs/api/submission-api.openapi.json` and the operation
  catalog contain 34 operations, while the authority's checked-in
  `specs/generated/submission-api.openapi.json` contains only 27.
- Resolution: runtime generation always starts from all five final `specs/api`
  documents, then applies documented corrections and regenerates all four
  TypeScript clients. Operation IDs are checked as exact sets.

## Unicode NFC implementation dependency is absent from the Cargo BOM

- The parser contract requires Unicode NFC normalization, but the authority
  Cargo BOM does not list a first-party normalization crate.
- Resolution: declare exact `unicode-normalization 0.1.24`, matching the
  already-resolved transitive version, so all extracted text meets the NFC
  contract without Python or native FFI in production.

## Submission create routines cannot satisfy record-bound field encryption

- Authority intent: every `gurine-fe-v1` envelope authenticates the exact
  schema, table, column, record UUID, logical type, and envelope version.
- Current evidence: multiple final migration routines generate the UUID inside
  PostgreSQL after accepting already-encrypted `bytea`. This makes it
  impossible for the caller to include that UUID in authenticated associated
  data. Draft-to-final correction submission also copies ciphertext to another
  table without rewrapping it for the final table context.
- Resolution: keep exactly 24 runtime migrations and close the boundary in
  `0024_v13_submission_session_boundary.sql`. Opaque submission sessions own a
  deterministic record UUID before protected fields are encrypted. Response
  answers are decrypted only inside the owning session scope and rewrapped for
  `intake.response_submissions` before the atomic final transition. No parallel
  `*_v2` procedure surface or extra migration is introduced.

## Response OTP promotion trusts a caller boolean

- Authority intent: `verifyResponseAccess(emailOtp)` verifies the proof and
  rotates a pending session to an active session with bounded attempts.
- Current evidence: the final authority routine accepts
  `p_verification_succeeded boolean`; no authority column stores an OTP hash,
  so a caller could assert success without proving possession.
- Resolution: the Submission API derives the expected OTP from the stored
  one-time access-token hash with `TOKEN_HMAC_KEY`, compares it in constant
  time, and is the only role allowed to invoke the locked promotion routine.
  Migration 0024 atomically increments attempts, applies lockout, consumes the
  pending session, and rotates to a new active opaque session. Integration
  coverage includes wrong OTP, lockout, success, rotation, and replay denial.

## Response extension routine uses an impossible status

- Current evidence: `intake.response_extension_requests.status` permits only
  `SUBMITTED`, `APPROVED`, or `REJECTED`, while the final authority routine
  inserts `PENDING`; every real call fails its table constraint.
- Resolution: migration 0024 replaces the same routine signature with an
  otherwise equivalent implementation that inserts `SUBMITTED`, the state
  representing a newly received extension request in the active schema.

## Dataset export creation omits a required lifecycle status

- Current evidence: `intake.dataset_export_requests.status` is `NOT NULL`, has
  no default, and permits `QUEUED`, `RUNNING`, `READY`, `FAILED`, or `EXPIRED`,
  while the authority `create_dataset_export` routine omits the column. Every
  real call therefore fails its not-null constraint.
- Resolution: the runtime routine inserts `QUEUED`, the initial state required
  by the export job lifecycle, in the same transaction as the request row.

## Public OpenAPI Money reference correction

- Current evidence: `ContractResponse.originalAmount` and `currentAmount`
  reference the generated lowercase `money` resource-envelope alias instead
  of the existing `Money` monetary schema.
- Resolution: the application OpenAPI YAML, canonical JSON, and generated JSON
  reference `Money`, so runtime validation enforces `amount` and `currency`.
  The hash-pinned authority tree remains unchanged.

## Control commands use canonical authority tables only

- Current evidence: the authority maps each Control operation to its canonical
  domain repository and requires idempotency, audit-chain, and outbox effects in
  the same transaction.
- Resolution: all 131 Control operations dispatch to typed handlers over the
  existing `core`, `editorial`, `intake`, `ops`, and `public` tables. The
  transaction writes the authority idempotency receipt, database-owned audit
  chain, and catalog-valid outbox event without introducing generic
  `control_resources`, `control_operation_log`, or shadow evidence tables.

## Runtime role closure and parser registry completion

- Current evidence: the final worker paths require narrowly scoped access that
  was absent from the broad baseline grants: notification delivery reads a
  submitted response under RLS, workflow jobs use selected `core` and `public`
  projections, Control reads source-document metadata, and the extractor must
  bind every result to an active parser implementation.
- Resolution: the existing five RLS policies retain token scoping while adding
  only the owning worker-role predicates. Schema and column/table grants are
  limited to the runtime queries. Migration 0024 seeds all 11 parser
  id/version/media-type entries with implementation digest
  `34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb`;
  the extractor refuses output whose registry status or digest differs.

## Control OpenAPI UUID-or-slug alias correction

- Current evidence: the generated `uuid-or-slug` component is an unrelated
  command-receipt object, although its references are aggregate identifier
  request fields such as `killSwitchId`.
- Resolution: the application OpenAPI YAML, canonical JSON, and generated JSON
  define the alias as a bounded non-empty string. This restores the intended
  UUID or stable slug wire contract without changing the pinned authority tree.

## Missing placeLegalHold capability annotation

- Current evidence: placeLegalHold is the only Control OpenAPI operation
  missing x-capability, while the generated Rust contract and assurance
  catalog require review.legal.
- Resolution: the application OpenAPI documents carry
  x-capability review.legal, matching the actor-assertion enforcement used
  by the Control API.

## RSP-004 has no dedicated attachment-list operation

- Authority intent: RSP-004 shows the current draft attachment list and lets
  the owning response session remove or replace a selected attachment.
- Current evidence: the screen-specific RSP-004 data-contract table declares
  create, finalize, and delete operations but no list operation. The integrated
  screen catalog nevertheless declares `getResponseDraft` as a blocking
  RSP-004 query, and `ResponseDraftResponse` contains the server-owned
  attachment metadata.
- Resolution: the response-portal BFF invokes the generated
  `getResponseDraft` client server-side under the same service assertion and
  scoped response session, and derives the attachment list from that response.
  Delete remains bound to the selected attachment UUID, CSRF token,
  idempotency key, and opaque session; the raw session token never reaches the
  browser. Delete followed by replacement upload is covered end to end. No new
  public operation or authority-spec edit is introduced.

## PUB-034 status navigation has no separate frontend route

- Current evidence: PUB-034 declares local-only `view-status`, while the route
  catalog defines the status/error surface only as `/{systemPath}` and does not
  define `/status`. The same screen already loads `getPublicSystemStatus` and
  orders its `impact` section above the action panel.
- Resolution: `view-status` navigates to the current screen's `#impact`
  landmark, exposing the live status and impact data without inventing a route
  outside the authority route map.

## Record navigation is undefined when a result set is empty

- Authority intent: local-only record actions open the concrete result selected
  or represented by server-projected data.
- Current evidence: several screen contracts declare such actions but do not
  specify a destination when the relevant query returns no record. Scrolling to
  an unrelated section would present an enabled action with no real target.
- Resolution: a record action is rendered only when a safe explicit,
  contextual, or server-projected destination can be derived. Empty collections
  hide the action; existing empty-state content remains visible. Unit and E2E
  coverage lock the destination mapping and protocol allowlist.

## Pinned authority tree remains unchanged

- All corrections above are implemented in source, generated application
  artifacts, runtime configuration, tests, or this deviation ledger. The
  hash-pinned authority package and the repository `specs/**` authority files
  are not modified.
