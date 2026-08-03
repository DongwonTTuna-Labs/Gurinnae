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
  Both the API lookup and migration 0024 select the access-token row by the
  pending session's exact `exchange_session_id`, never by the request alone.
  Migration 0024 atomically increments attempts, applies lockout, consumes the
  pending session, and rotates to a new active opaque session. Integration
  coverage includes multiple tokens for one request, wrong OTP, lockout,
  success, rotation, and replay denial.

## Synthetic browser challenge cannot hold the verifier secret

- Authority intent: anonymous browser submissions carry a short-lived abuse
  proof, while `BOT_CHALLENGE_SECRET_KEY` belongs only to `submission-api` and
  must never be exposed to the browser or `public-web` runtime.
- Resolution: in non-production synthetic mode the browser creates only a
  random nonce. The public BFF validates its action and age, then signs the
  nonce with its existing request-bound service HMAC key using a dedicated
  domain. Submission API verifies the current or previous issuer key and still
  accepts the authority-compatible direct synthetic verifier signature for
  integration callers. Production rejects the synthetic provider before
  either path.

## Public case relation filters require multi-valued projection metadata

- Authority intent: case lists and agency, supplier, and rule case routes
  filter published cases by their real linked relations.
- Current evidence: a case can link multiple anomaly signals, while the
  publication payload had no relation metadata and fixture-only singular keys
  concealed the missing production path.
- Resolution: publication derives sorted unique `agencyIds`, `supplierIds`,
  and `ruleIds` from linked signals, their rule versions, and contract targets.
  Public SQL filters these arrays before pagination while retaining singular
  key compatibility for older projected rows. Relation metadata is stripped
  from public case and revision responses.

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

## Kill-switch extension request omits an expiry value

- Authority intent: `extendKillSwitch` extends an active switch while every
  switch remains bounded by an expiry; indefinite switches are explicitly
  forbidden.
- Current evidence: the final `extendKillSwitchRequest` contains only
  `killSwitchId`, `reason`, and `expectedVersion`, although the persistence
  statement requires an expiry update.
- Resolution: each successful extension advances the later of the stored
  expiry and current database time by one bounded hour. A legacy null expiry is
  repaired to one hour from database time instead of becoming indefinite. The
  transaction still enforces active state, optimistic versioning, STEP_UP,
  audit, and idempotency.

## Audit export schema has no authorized download operation

- Current evidence: `AuditExportResponse.downloadUrl` is required but nullable,
  while the final Control operation catalog defines creation and status lookup
  only. No actor-assertion-bound download operation or route exists.
- Resolution: status lookup returns `downloadUrl: null` even after an internal
  object key is materialized. It never advertises the former invented
  `/v1/internal/audit-exports/{id}/download` path that always returned 404. The
  protected object key and content digest remain server-side, and no route
  outside the authority API is invented.

## Hash-pinned authority package remains unchanged

- The sole input authority ZIP remains byte-identical at SHA-256
  `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`.
  No earlier Gurine version or separate product material is used.
- The repository `specs/**` tree preserves the pinned package's exact 791-file
  member set. A byte audit against the pinned extraction finds 239 differing
  files: 225 JSON/YAML files parse to identical values and differ only in
  deterministic source formatting.
- The remaining 14 paths are the already-documented application corrections
  or formatting of non-structured reference assets:
  `specs/api/{control-api,public-api}.openapi.{json,yaml}`,
  `specs/config/secret-and-key-catalog.yaml`,
  `specs/deployment/{compose-reference,service-config-map}.yaml`,
  all four `specs/generated/*.openapi.json` files, and
  `specs/ui/final-reference/{app.js,index.html,styles.css}`. Their functional
  changes close the OpenAPI, runtime-config, generated-client, and inert-link
  defects recorded above; the JS/CSS remainder is formatter-only.
- The immutable pinned extraction is never edited. Every repository correction
  is included in `MANIFEST.sha256` and exercised by the strict authority,
  code-generation, runtime, container, E2E, visual, and clean-extraction gates.
