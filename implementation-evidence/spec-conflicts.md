# Authority Specification Conflicts

The precedence in `AGENTS.md` is binding. This file records conflicts rather than
silently combining incompatible requirements. Each resolution remains fail-closed.

## SPEC-CONFLICT-001 — External operation counts

- Lower statement: `tests/acceptance/route-operation-completeness.feature` requires
  Public 42, Control 125, Submission 22.
- Higher statements: `FINAL_BUILD_CONTRACT.md` and
  `specs/product/final-product-contract.yaml` require Public 41, Control 131,
  Submission 34, plus six browser Identity flows; private Identity has nine
  operations.
- Resolution: preserve and implement every original `41/131/34 + 6 browser
  Identity` operation and the nine private Identity operations. The owner addendum
  then adds 29 Control and eight Submission operations, producing the final
  external release count `41/160/42 + 6 browser Identity = 249`. The complete HTTP
  catalog is 266 after adding the preserved nine private Identity operations and
  eight private communication callbacks. Preserve the acceptance scenario's intent
  that all operations are exposed exactly once, schema-conformant, and globally
  unique.
- Rejected alternative: change implementation or generated APIs to the stale
  `42/125/22` split.
- Required follow-up: correct the scenario expectation to the owner-approved final
  count, regenerate its executable mapping, and retain both base-preservation and
  final total/count assertions.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-002 — Agent citation outside snapshot

- Lower statement: `tests/acceptance/prompt-injection.feature` says an agent task
  with an unknown Evidence ID becomes `REJECTED`.
- Higher agent policy: `specs/agents/*/output.schema.json`, prompts, fixtures, and
  `specs/agents/reference_harness.py` define `ABSTAINED` with
  `EVIDENCE_OUTSIDE_SNAPSHOT` and no partial application.
- Resolution: the AgentRun output is `ABSTAINED/EVIDENCE_OUTSIDE_SNAPSHOT`; any
  separately persisted proposal/application command is not created. The safety
  intent of zero partial state change remains unchanged.
- Rejected alternative: invent `REJECTED` as an AgentRun status outside the exact
  agent output schemas.
- Required follow-up: correct only the conflicting acceptance status and assert
  absence of proposal, claim mutation, and authoritative state change.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-003 — PRICE_OUTLIER blockers and fixture semantics

- Lower statement: `tests/acceptance/price-comparability.feature` uses
  `BUNDLE_UNKNOWN`, `UNIT_INCOMPATIBLE`, `VAT_UNKNOWN`, `CONTRACT_CANCELLED`, and
  `INSUFFICIENT_DATA`, and models a richer known-bundle status.
- Higher detection authority: `specs/detection/rules/price_outlier.yaml`, its oracle,
  reference evaluator, and 30 evals define `REQUIRED_FIELD_MISSING`,
  `INSUFFICIENT_COMPARABLES`, `TARGET_BUNDLE_UNKNOWN`, and `TARGET_VAT_UNKNOWN`.
  Incompatible comparable units are excluded from the cohort; the run is blocked
  only when fewer than eight comparables remain.
- Resolution: production detection output remains byte-for-byte compatible with the
  higher oracle. Acceptance uses the authoritative blocker vocabulary and asserts
  excluded IDs, cohort size, and outcome. Contract cancellation and richer bundle
  semantics may be validated at normalization/cohort-selection boundaries but may
  not invent new v1.0.0 rule output.
- Rejected alternative: change the oracle, rule output schema, or expected 300 evals
  to match the lower acceptance prose without a new approved rule version.
- Required follow-up: repair the feature fixtures/expectations for this conflict and
  add exact oracle-equivalence receipts.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-004 — Legacy combined case states

- Lower statement: `tests/acceptance/case-lifecycle.feature` names
  `DISMISSED_DATA_ERROR`, `PUBLISHED_ANOMALY`, and `CORRECTION_REVIEW` as one case
  state axis.
- Higher state authority: `specs/domain/state-machines.yaml` and typed domain models
  use orthogonal lifecycle, disposition, publication, and correction state.
- Resolution: implement the exact higher-order orthogonal state model. Acceptance
  setup and assertions express the same business journeys as tuples of the correct
  axes and verify one atomic version/audit transition.
- Rejected alternative: add legacy combined strings to the production lifecycle
  enum or collapse the orthogonal axes.
- Required follow-up: record the exact tuple for each affected scenario and add
  positive/negative DB and application assertions.
- Status: `OPEN_IMPLEMENTATION`.

Exact tuple resolution:

- `AC-CASE_LIFECYCLE-002`: `(SIGNAL_DETECTED, NEVER_PUBLISHED, NONE)`; a direct
  investigation transition to `READY_TO_PUBLISH` is `INVALID_STATE_TRANSITION`
  with no axis/version mutation.
- `AC-CASE_LIFECYCLE-004`: `(CLOSED, NEVER_PUBLISHED, DATA_ERROR)`; canonical
  `reopen-case` produces `(INVESTIGATING, NEVER_PUBLISHED, DATA_ERROR)` after all
  reopen guards and preserves the historical resolution.
- `AC-CASE_LIFECYCLE-005`: `(READY_TO_PUBLISH, PUBLISHED_ANOMALY, NONE)`; entering
  correction review advances the separate correction aggregate to `REVIEW` while
  the case tuple and immutable public revision remain unchanged.

## SPEC-CONFLICT-005 — Acceptance package and fixed Cargo-member count

- Lower executable mapping: Rust scenarios invoke package
  `gurine-acceptance-tests`.
- Higher fixed topology: the product has exactly 32 base Cargo members and already
  assigns `crates/test-support` as its test-support member.
- Resolution: `crates/test-support` remains the existing member path and owns the
  package name `gurine-acceptance-tests` and all acceptance test targets. No
  thirty-third base member is added. Current mapping truth is 202 Rust scenarios
  in 28 Rust files and 69 browser scenarios in seven Playwright files.
- Rejected alternatives: add a new product Cargo member, leave the mapped package
  unresolved, or report the incorrect 26/9 file split.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-006 — Canonical runtime SLO

- Conflicting statements: `docs/11-operations-and-cost.md` and
  `specs/deployment/production-topology.yaml` declare different pilot thresholds.
- Resolution: release, dashboard, alert and capacity evidence use the stricter
  compatible target: public availability 99.5% per UTC month; Control availability
  99.0%; cached public API P95 300 ms; uncached public API/search P95 800 ms;
  Control query P95 1500 ms; command acknowledgement P95 1000 ms; SSR TTFB P95
  800 ms; public LCP P75 2500 ms; CLS at most 0.1; correction propagation P95 ten
  minutes; near-real-time source lag P95 two hours; daily source lag P95 24 hours.
- Rejected alternative: select a looser target by environment default.
- Status: `DECISION_COMPLETE`.

## SPEC-CONFLICT-007 — Owner addendum and fixed catalog counts

- Base statements: v13 fixes 24 migrations, 107 active tables, 99 events, and 212
  external operations.
- Owner addendum: the 2026-07-14 instruction requires typed AI/tool/snapshot,
  approval, omnichannel, rights, governance, and product-economics contracts that
  cannot be represented by the base catalog without semantic overloading.
- Resolution: the base contracts are mandatory compatibility minima and may not be
  deleted or repurposed. Base migrations `0001` through `0024` are byte-identical
  in the spec and runtime trees; implementation corrections are post-base only.
  The source-derived physical candidate decision is now
  `specs/database/addendum/physical-adjudication.yaml`: its review-required v2 set
  has 19 `NEW`, 8 `MAP`, and 2 `NONPHYSICAL` decisions. Once every listed contract
  and migration exists, the planned inventory is six post-base migrations,
  125 additive tables, and 232 active tables. Until that compiler/catalog gate
  passes, these numbers are planned design facts and not runtime facts. The safe
  response-extension request v2 event remains additive because the dormant base v1
  requires a secret token payload and declares no producer. The current operation
  design remains 249 external and 266 complete HTTP operations; three surfaces and
  94 routes remain unchanged.
- Rejected alternatives: generic JSON action payload, use an unrelated existing
  operation, mutate migrations 0001–0024, or claim an adapter without persistence
  and acceptance evidence.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-011 — Response SENT fact and delivery clock ownership

- Conflicting lower statements: `materializeResponseRequestSent` inserted an
  `EVIDENCE_PENDING` clock row and referenced phantom endpoint/provider version
  relations, while the 0027 clock relation requires a verified applied
  `DELIVERED|READ` observation and complete calendar/due fields. The legacy
  notification worker also treated an SMTP send return as `DELIVERED` without a
  typed immutable receipt and left the response request in `DRAFT`.
- Resolution: authenticated provider acceptance alone materializes `DRAFT -> SENT`
  through `editorial.response_request_sent_receipts`. A separate delivery
  observation owns the first verified `DELIVERED|READ` clock decision;
  `EVIDENCE_PENDING` is derived from the absence of that decision and is never a
  placeholder row. The exact endpoint revision, provider preflight snapshot,
  rendering, access artifact, delivery receipt, audit, and outbox IDs/digests are
  bound in one serializable logical-consumer inbox transaction. Unknown or
  possibly-sent outcomes enter reconciliation and never advance the request.
- Rejected alternatives: update `SENT` directly in the notification worker, use a
  mutable provider head as historical evidence, start the clock on provider
  acceptance, create a synthetic pending clock row, or retry an ambiguous external
  effect blindly.
- Required follow-up: propagate the physical relation/event/consumer/inbox contract,
  implement the seed-free create-to-owned-intake journey, and pass PostgreSQL 18.4
  catalog, replay, crash, race, and 64-client tests.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-008 — Legal-hold release has no base operation

- Trust and retention requirements require scoped, audited hold release; v13 has
  release columns but only the `placeLegalHold` operation.
- Resolution: the owner addendum adds Control operation `releaseLegalHold`. It
  binds hold ID/digest, exact affected IDs/scope, expected version, authority,
  reason and legal actor, and produces `legal.hold_released.v1` plus an immutable
  receipt. Expiry creates review work and never releases silently.
- Rejected alternatives: treat `expiresAt` as release, overload `submitReview`, or
  update `editorial.legal_holds` manually.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-009 — Integrated-search scope and result schema

- UI authority: PUB-002 searches cases, contracts, agencies, suppliers,
  methodology and corrections; INT-003 searches cases, signals, evidence, agent
  runs and audit. Fixed operations expose only their declared filters.
- API gap: base search items are generic and lack typed match, object revision,
  item freshness, rank policy, generation and watermark.
- Resolution: retain exact type/filter sets and operation paths. The owner addendum
  adds backward-compatible `SearchMatchV1`, object revision/freshness and page
  projection/ranking fields plus typed SearchDocument projections/ownership in
  DESIGN §7. Runtime must populate them; absent legacy fields render partial, never
  a synthetic reason.
- Rejected alternatives: expose SOURCE/DATASET/RULE/TASK without screen amendment,
  encode reason into summary, browser-compute highlights, or generic new search op.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-010 — Locator vocabulary and public trace fields

- Base parser kinds are PAGE_BBOX, XLSX_CELL, CSV_ROW_COLUMN, XML_XPATH,
  DOCX_PARAGRAPH and HWPX_XPATH.
- Conflicting prose used replacement names that would lose base locator identity;
  base PublicEvidence also lacks source authority/retrieval fields needed by public
  comprehension and provenance acceptance.
- Resolution: preserve all six base kinds and add only JSON_POINTER,
  HTML_CSS_SELECTOR, API_FIELD and TEXT_RANGE. Presentation labels never replace
  persisted kinds. Material locator/PublicEvidence carries exact asset revision,
  content/selection digest, retrieval time, authority, parser and transformation
  fields in DESIGN §7.
- Rejected alternatives: rename base kinds, resolve against live/latest asset,
  treat case freshness as evidence retrieval, or silently jump revision.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-012 — Cost export binary versus shared download envelope

- Conflicting authority rows: `specs/api/operation-contracts.yaml` requires
  `exportCostReport.response_fields.binary` plus filename/media type/length and
  checksum evidence, while the shared `BinaryDownload` resource originally
  required only `id/status/version` and forbade additional properties.
- Resolution: preserve the shared envelope for existing download operations and
  extend its closed schema with optional receipt metadata.  The control API's
  `exportCostReport` path is a server-owned subtype: `response_for` preserves the
  immutable CSV/JSON bytes and the handler MUST emit `binary`, `contentBase64`,
  `contentSha256`, `receiptSha256`, filename, media type, byte length, period and
  grouping.  The owner SECURITY DEFINER projection reads the reservation,
  settlement and cost-event ledger with a half-open `[from,to)` window; no
  direct ledger table privilege is granted to the control role.
- Rejected alternative: silently strip the binary fields through the generic
  materializer or synthesize a zero-cost report from `agent_runs`.
- Required follow-up: generated OpenAPI/client schemas, response samples and a
  live authenticated OPS-004 export witness must all carry the same content and
  receipt digests before release freeze.
- Status: `DECISION_COMPLETE`.

## SPEC-CONFLICT-013 — Response route parameterization versus static screen sheets

- Conflicting authority rows: `specs/ui/routes.md` and
  `specs/traceability/final-traceability.yaml` require the response journey at
  `/respond/{token}` and `/respond/{token}/...`, while the individual RSP screen
  sheets (`specs/ui/screens/RSP-001.md` through `RSP-007.md`) and the existing
  source tree name static routes such as `/respond/access` and
  `/respond/overview`.
- Resolution: the parameterized routes are the canonical production contract
  because the higher-level route catalog and traceability contract bind the
  response token to the session boundary. Static paths remain deterministic
  local fixture aliases only; they must never issue or accept a response
  session without a token exchange. Any route parity test must assert both the
  canonical token route and the explicitly marked fixture alias.
- Rejected alternative: silently choose static paths in production or infer a
  token from cookies/query state, which would break the request-bound session
  and IDOR protections.
- Required follow-up: add token-route adapters and route tests, update screen
  route metadata to distinguish canonical and fixture aliases, and record a
  fresh SSR/DOM/AX witness for every RSP route.
- Status: `OPEN_IMPLEMENTATION`.

## USER-ADDENDUM-001 — 2026-07-14 product steering

- Statement: the product owner requires low-cognitive-load journeys, consistent
  product design, a coherent revenue loop, actual multimodal/Internet analysis,
  human approval, and major messaging channels.
- Interpretation: this is additive authority from the authority owner. Exact
  additive operations, tables, events, adapters, counts, and fixed-screen ownership
  are declared in `specs/product/owner-addendum-2026-07-14.yaml`; canonical Rust and
  persistence ownership is declared in
  `implementation-evidence/design-domain-closure.yaml`. It never reduces an
  original screen, operation, scenario, security, publication, consent, evidence,
  or no-placeholder requirement.
- Boundary: provider credentials, sender approvals, legal approvals, and selected
  commercial payment mechanics remain explicit deployment inputs. Unconfigured
  capabilities fail closed and cannot be reported as operational.
- Status: `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-UIR-001 — interface-restraint §3 full composition vs frozen v13 contracts

- Lower statement: `specs/ui/interface-restraint.md` §1/§3 requires prev/next navigation,
  compare shelf, global freshness timestamp and ledger naming.
- Higher statement: hash-pinned v13 screen catalog/build manifest freeze section sets,
  screen titles and data operations; the plan forbids new data calls this round.
- Resolution: implement density/typography/copy restraint now (restraint §7 staged
  application); defer prev/next, compare shelf, global freshness slot and ledger naming
  to a contract-amendment round. No invented data, fail-closed preserved.
- Status: OPEN_IMPLEMENTATION (follow-up: contract amendment round).

## SPEC-CONFLICT-014 — Source connector activation receipt has no bootstrap owner

- Binding statement: `specs/config/source-connectors.yaml` requires a credentialed
  or official-link preflight receipt and recorded response fingerprint before a
  connector is activated. PPS sanctions additionally requires reuse-rights
  approval and an exact CSV schema fingerprint.
- Current physical path: `services/control-api/src/service/domains/sources.rs`
  admits `runSource`/`retrySourceRun` from `ops.source_registry.enabled` plus
  `legal_status='APPROVED'`; `services/ingest-worker/src/ingest_jobs.rs` claims the
  run using the same registry state plus the closed environment allowlist. The
  only writer for `configuration.activationReceipt` is `finish_source_run`, after
  an ordinary source run has already fetched and completed successfully. There is
  no connector-preflight operation, immutable receipt relation, owner routine, or
  approved receipt input that can exist before that first run.
- Preserved resolution for R6c: keep every new connector disabled by default,
  retain the independent environment and registry gates, and keep PPS sanctions
  production activation explicitly blocked. Do not require the post-run receipt
  in the worker claim yet, because that would make the first legitimate preflight
  permanently unreachable.
- Rejected alternatives: manufacture a static receipt, reinterpret an ordinary
  data run as preflight, reuse the unrelated communication-provider receipt
  schema, or let a mutable JSON field alone attest rights and credential checks.
- Unlock condition: authority must define a connector-specific preflight
  operation, immutable receipt schema and owner writer, the exact credential /
  rights / quota / response-fingerprint proof fields, expiry/revocation rules,
  and the atomic transition that enables `ops.source_registry`. Control enqueue
  and worker claim can then require that exact current receipt.
- Status: `OPEN_AUTHORITY_DECISION`.

## SPEC-CONFLICT-015 — Connector base-URL environment and registry authority diverge

- Binding/configuration statement: `specs/config/secret-and-key-catalog.yaml`,
  `specs/deployment/service-config-map.yaml`, `compose.yaml`, and
  `infra/scripts/production-preflight.sh` declare and validate
  `KONEPS_CONTRACT_API_BASE_URL`, `KONEPS_NOTICE_API_BASE_URL`,
  `KONEPS_BID_RESULTS_API_BASE_URL`, and `OPEN_DART_API_BASE_URL` on the egress
  gateway when the corresponding connector is enabled.
- Current physical path: the egress gateway consumes none of those four values;
  it owns only exact host bindings and credential injection. The ingest worker
  builds targets exclusively from `ops.source_registry.base_url` returned by
  `process_source_run`. No migration, startup owner, or Control operation
  atomically reconciles the environment values into that registry row. Therefore
  a production preflight can accept an environment URL while the runtime registry
  remains absent, stale, or path-divergent and later fails closed with
  `SOURCE_BASE_URL_MISSING`/a different target.
- Preserved resolution for R6c: retain `ops.source_registry.base_url` as the
  current runtime authority and the gateway's exact host allowlist; do not add an
  undocumented mutable startup writer or let the worker silently prefer an
  environment value.
- Rejected alternatives: environment-over-registry fallback, gateway path
  rewriting, treating preflight presence as registry equality, or seeding a
  production-enabled connector without activation evidence.
- Unlock condition: authority must choose one source of truth. Either define an
  owner-controlled, digest-bound, atomic environment-to-registry reconciliation
  and equality preflight, or remove the dead base-URL environment contract and
  make the versioned registry configuration plus activation receipt the sole
  deployment input.
- Status: `OPEN_AUTHORITY_DECISION`.

## SPEC-CONFLICT-016 — Correction publication event cardinality diverged across active contracts

- Conflicting statements: the active base rows for `resolveCorrectionRequest` in
  `specs/api/operation-persistence.yaml`, `specs/application/command-semantics.yaml`,
  `specs/database/operation-table-matrix.yaml`, `specs/architecture/command-catalog.yaml`,
  and `specs/traceability/final-traceability.yaml` declared only
  `correction.resolved.v1` and `notification.correction_resolved.v1`, while
  `specs/product/addendum-command-semantics.yaml` and
  `specs/product/addendum-persistence-contracts.yaml` required the RESOLVED branch
  to create a CORRECTED publication revision and projection but described its
  outbox cardinality as exactly three.
- Higher invariant and resolution: a successful RESOLVED transition atomically
  emits exactly one each of `correction.resolved.v1`,
  `notification.correction_resolved.v1`, `publication.revision_created.v1`, and
  `projection.publication_revision_created.v1`. The base mirrors, addendum
  cardinality, and both publication event producer sets are aligned to that exact
  four-event set.
- Rejected alternatives: retain the two-event base set and omit publication
  lifecycle evidence, or retain an exactly-three addendum by dropping either the
  correction notification or the projection event. Both alternatives contradict
  the existing atomic correction-to-publication transition and its consumers.
- Status: `RESOLVED_R6D`.

## SPEC-CONFLICT-017 — Privacy receipt replay versus current access-policy resolution order

- Conflicting statements: the active `exchangePrivacyRequestReceiptToken`
  command semantics require resolving exactly one current, approved, effective,
  and unexpired `privacy_request_receipt_access_policy` before the idempotency
  claim, while `specs/submission/addendum-derived-session-boundary.yaml`
  describes an exact idempotency replay as returning the stored public bytes
  after the one-shot receipt has been consumed, including across cookie-profile
  rotation.
- Higher authority and resolution: command-semantics ordering remains binding.
  Every first attempt and replay resolves the current access policy and its
  cookie profile before consulting or returning a stored exchange receipt. A
  missing, duplicate, expired, unapproved, ineffective, or rotated-away policy
  or profile fails closed with request-id-only `DEPENDENCY_UNAVAILABLE` (HTTP
  503) and zero writes. Stored-byte replay is available only after that current
  policy gate succeeds and the stored policy identity, revision, digest, and
  profile binding remain valid.
- Rejected alternative: move the idempotency lookup ahead of policy resolution
  and always return historical session bytes. That ordering could revive a
  session under a withdrawn policy or obsolete cookie profile and would bypass
  the approved current-policy fail-closed boundary.
- Status: `RESOLVED_R6D`.

## SPEC-CONFLICT-018 — Privacy V2 transition authority is incomplete for two branches and one proof kind

- Binding contract: `transitionRetentionRequest` is the closed discriminated V2
  owner for `VERIFY_IDENTITY|START_REVIEW|APPROVE|REJECT|EXTEND`; `COMPLETE`
  belongs only to the retention worker. The operation may consume only immutable,
  scope-bound receipts and may not fall back to the historical V1 decision or
  execution path. See `specs/product/addendum-command-semantics.yaml`,
  `specs/product/addendum-persistence-contracts.yaml`, and
  `specs/product/addendum-state-machines.yaml`.
- Current physical availability:

  | Branch | Current state | Missing authority |
  | --- | --- | --- |
  | `START_REVIEW` | implemented | none after the request is already `VERIFIED` and carries its exact policy/calendar binding |
  | `EXTEND` | implemented | none for a request with an authoritative verified clock and one current approved response policy/calendar; the policy row, not the event schema, supplies the effective maximum duration and count |
  | `REJECT` | implemented | none for a request with an authoritative verified clock and policy/calendar; the owner appends the discriminated decision and refusal-notice receipt/event chain |
  | `VERIFY_IDENTITY / RESPONSE_RECEIPT` | implemented | the immutable same-subject exact-scope authority receipt, one-time proof-consumption receipt, V3 owner, and receipt/event graph are implemented |
  | `VERIFY_IDENTITY / VERIFIED_ENDPOINT` | `OPEN_FAIL_CLOSED` | the privacy authority consumer is closed, but no canonical endpoint verifier/runtime producer can create the required source receipt |
  | `APPROVE / CORRECTION / RESPONSE /partyName` | implemented | exactly one current sealed plan and immutable 0040 ACCESS-authority binding, complete OBJECT_SET inventory, current response/receipt-chain projection and zero-active-hold coverage are revalidated; the existing approval event and exactly one dedicated job are created atomically without applying the value |
  | worker `COMPLETE / CORRECTION / RESPONSE /partyName` | implemented | the dedicated workflow worker revalidates the claimed job lease/fencing token, plan, approval, response version/value digest, authority chain, hold coverage and payload digest before the response-domain owner writes one immutable completion receipt and one redacted completion event |
  | all other `APPROVE` / worker `COMPLETE` branches | `OPEN_FAIL_CLOSED` | no typed effect owner exists for `ACCESS`, `DELETION`, `RESTRICTION`, or any CORRECTION target other than the exact RESPONSE `/partyName` cell |

- Safe resolution: each unavailable branch or proof-kind path raises its closed PVT/SQLSTATE `55000`
  dependency failure before mutation and preserves canonical zero-write state. The
  service maps the closed unavailable result without substituting a success,
  synthetic evidence, or a legacy execution path.
- Rejected alternatives: accept caller proof or a boolean `legal_reviewed`-style
  assertion as identity authority; reuse endpoint possession or organization
  identity receipts without an exact privacy subject/scope binding; fabricate an
  inventory or legal-hold coverage digest; infer completion from request state or
  an audit row; emit a generic completion receipt without the request-type effect
  and location receipt set; or call the V1 retention decision/execution owner.
- Unlock conditions: add the canonical verified-endpoint verifier/runtime producer;
  and add separate typed executors and immutable completion receipts for
  `ACCESS`, `DELETION`, `RESTRICTION`, and any future exact CORRECTION cell. Each
  addition requires its own authority decision and negative/replay/zero-write
  runtime probes before that branch can be marked available.
- Status: `VERIFY_IDENTITY / RESPONSE_RECEIPT`, `START_REVIEW`, `EXTEND`, and
  `REJECT` are `RESOLVED_R6D` under the latest discriminated contract. The exact
  `CORRECTION / RESPONSE /partyName` APPROVE and worker COMPLETE branches are
  `RESOLVED_R6D_Q4`; `VERIFY_IDENTITY / VERIFIED_ENDPOINT` and every other
  APPROVE/COMPLETE branch remain `OPEN_FAIL_CLOSED`.

## SPEC-CONFLICT-019 — Typed privacy correction plan does not define correction effects

- Binding statements: R6d supervisor decision D3 requires an immutable typed
  correction plan containing the target object, field path, current-value digest,
  requested value and evidence, and requires the existing human approval path to
  consume it. The original T5 completion request also requires the privacy
  pipeline to become executable rather than remain design-only.
- Superseding authority: R6d supervisor Q4 permits only subject-claimed contact or
  display information and manifest typographical errors. Procurement facts,
  contract amount/date/award result, agency or supplier identity, detection
  results, publication decisions and audit records are forbidden. The
  current-value digest must come from the same subject-bound source used to build
  the ACCESS response, and application must be owned by each target domain after
  human `APPROVE` and complete only through the worker receipt chain.
- Resolved physical mapping: the authorized exact allowlist contains one pair,
  `RESPONSE` plus `/partyName`. The target is the materialized
  `editorial.responses.id` bound from an exact same-subject `RESPONSE_RECEIPT`
  through the response submission receipt and immutable origin receipt. The
  capability-gated ACCESS workspace and correction plan both call the same
  `ops.read_privacy_response_party_name_access_v1` owner, whose
  `currentValueDigest` is SHA-256 of the exact UTF-8 `partyName` and whose
  `projectionDigest` covers the complete authority preimage.
- Authority-marker resolution: the reused 0039 generic plan row still records
  `currentValueAuthority=HUMAN_REVIEWER_ASSERTION`. That marker is subordinate
  provenance for the caller comparison input and is not treated as ACCESS
  authority. The immutable 0040 plan binding records
  `RESPONSE_PARTY_NAME_ACCESS_PROJECTION_V1` with the response version, current
  value, projection and receipt-chain digests; APPROVE and COMPLETE revalidate
  this final binding. This forward binding resolves the apparent conflict without
  rewriting historical plan rows.
- Executable effect: human APPROVE preserves the existing
  `privacy.request_decision_recorded.v1` event and creates exactly one dedicated
  `PRIVACY_RESPONSE_PARTY_NAME_CORRECTION` job plus immutable approval binding in
  the same transaction. It mutates zero response rows. The claimed workflow job
  alone decrypts the sealed value in zeroized memory, and the response-domain
  database owner rechecks the current response version/value digest, plan,
  receipts, hold coverage and job fence before updating `party_name`, appending
  one immutable completion receipt and emitting
  `privacy.response_party_name_corrected.v1` without plaintext.
- Remaining fail-closed catalog: every pair other than exactly RESPONSE plus
  `/partyName` returns `PRIVACY_CORRECTION_TARGET_UNSUPPORTED` (HTTP 422,
  SQLSTATE `0A000`) before encryption, idempotency claim or owner writes. There is
  no wildcard, prefix, inferred column or reviewer override. Subscription email,
  communication endpoint bytes, `PUBLICATION`, `EVIDENCE`,
  `AUDIT_SUBJECT_RECORD`, procurement facts, detection results, publication
  decisions and audit records remain unsupported.
- Rejected alternatives: invent a generic JSON mutation adapter; infer fields from
  physical columns; treat the caller/reviewer digest as a server comparison;
  reuse the request-scope digest as a field-value digest; or interpret the freeform
  privacy statement as executable authority.
- Expansion condition: any second pair requires a new exact subject binding,
  requested-value type/normalization, ACCESS projection and current-value digest
  derived from the same source/version fence, typed domain apply owner,
  legal-hold recheck, immutable application receipt and worker completion binding.
  The non-authorizing candidate list is maintained in
  `docs/legal/privacy-correction-field-backlog.md`; adding a column name or
  accepting a reviewer digest alone is insufficient.
- Status: `RESOLVED_R6D_Q4_EXACT_ONE_CELL` for RESPONSE `/partyName`; all other
  pairs remain `EXPLICITLY_UNSUPPORTED_FAIL_CLOSED`.

## SPEC-CONFLICT-020 — Seven privacy object kinds lack four concrete legal-hold anchors

- Binding statement: R6d supervisor decision D3 requires an explicit concrete
  legal-hold mapping for `RESPONSE`, `CORRECTION`, `SUBSCRIPTION`,
  `COMMUNICATION_ENDPOINT`, `PUBLICATION`, `EVIDENCE`, and
  `AUDIT_SUBJECT_RECORD`; a generic or merely comprehensive anchor declaration is
  forbidden.
- Superseding authority: R6d supervisor decision Q5 closes three mappings and
  explicitly declines to invent the fourth. `CORRECTION` binds one immutable
  `ops.privacy_correction_snapshots_v1(snapshot_id, correction_id,
  snapshot_version, snapshot_digest)` row: `targetId=correctionSnapshotId`,
  `targetVersion` is the snapshot version,
  `targetDigest=correctionSnapshotDigest`, and `correctionId` preserves the object
  binding. `SUBSCRIPTION` binds
  `ops.privacy_subscription_snapshots_v1(snapshot_id, subscription_id,
  snapshot_version, snapshot_digest)` equivalently. `COMMUNICATION_ENDPOINT`
  binds the existing `intake.communication_endpoints(id, version,
  endpoint_digest)` tuple exactly; an `endpointSnapshotDigest` substitute is
  forbidden.
- Unsupported target resolution: `AUDIT_SUBJECT_RECORD` has no authoritative
  source relation. It is not admitted to `LegalHoldTargetBindingV1` and no anchor
  is manufactured. The Control boundary recognizes that discriminator before
  generic shape validation and returns typed
  `LEGAL_HOLD_TARGET_UNSUPPORTED` (HTTP 422) with zero writes. The database owner
  independently preserves the same fail-closed rejection.
- Contract resolution: the prior ten supported target branches remain unchanged
  and the three authorized mappings extend the closed union to thirteen. Privacy
  hold coverage evaluates `RESPONSE`, `PUBLICATION`, `EVIDENCE`, `CORRECTION`,
  `SUBSCRIPTION`, and `COMMUNICATION_ENDPOINT` only through their explicit
  immutable bindings; neither `PRIVACY_REQUEST` nor `COMMUNICATION_SUBJECT`
  transitively stands in for another object kind.
- Rejected alternatives: map `CORRECTION` to its case or publication implicitly;
  map `SUBSCRIPTION` or `COMMUNICATION_ENDPOINT` to a communication subject;
  manufacture an `AUDIT_SUBJECT_RECORD` UUID/digest; or claim a privacy-request
  anchor transitively covers all inventory members.
- `AUDIT_SUBJECT_RECORD` unlock condition: authorize a versioned immutable source
  relation, canonical target-digest preimage, owner lock, immutable anchor columns
  and foreign key, placement/release validation and event payload branch. Merely
  adding a UUID or a broad audit-table declaration does not satisfy this condition.
- Status: `CORRECTION`, `SUBSCRIPTION`, and `COMMUNICATION_ENDPOINT`
  `DECISION_COMPLETE_R6D`; `AUDIT_SUBJECT_RECORD`
  `EXPLICITLY_UNSUPPORTED_FAIL_CLOSED`. The authority conflict is resolved without
  claiming unsupported coverage.

## SPEC-CONFLICT-021 — Backup physical-disposal receipt is operator-owned and deferred

- Binding statement: R6d supervisor decision D1 assigns backup disposal after the
  one-year deadline to the existing `infra/scripts` backup and restore operator,
  requires a disposal procedure and immutable execution receipt, and forbids an
  automatic deletion implementation in this wave.
- Current authority gap: the existing database roles are application-service
  boundaries and no authenticated database writer represents the filesystem
  backup operator. Authority also does not define backup-artifact identity or the
  entity-to-artifact cardinality, the exact external receipt fields and
  append-only storage, operator identity, permitted disposal methods and their
  success evidence, or the evidence that independently proves absence across all
  authoritative backup locations.
- Safe implementation: the database derives a bounded, deterministic due
  inventory only from immutable entity-retention execution receipts whose
  `backupDisposalDueAt` has passed. The inventory performs no deletion, creates no
  job or completion attestation, and remains repeatable; an item means a due
  candidate and does not prove whether any backup artifact currently exists.
- Superseding authority: supervisor R6d Q2 designates the completion-receipt path
  `OPERATOR_OWNED_DEFERRED`; no receipt ABI is authorized for this repository.
- Implemented boundary: the existing operator may export deterministic due
  candidates and resolve disposal targets under the current backup/restore
  boundary. The system has no receipt producer, storage, verifier, completion
  attestation, or completed-item exclusion and therefore cannot claim disposal
  completion.
- Rejected alternatives: invent a database disposal-receipt relation or writer,
  grant `gurine_migrator`/superuser as an application authorization model, add a
  new role or capability, or manufacture `backupSetDigest`,
  `operatorReferenceDigest`, disposal-method enum values, artifact cardinality or
  absence-verification semantics.
- Resume condition: `BACKUP_PHYSICAL_DISPOSAL_RECEIPT_AUTHORITY` must supply the
  external storage, producer authentication, artifact N:M identity, disposal
  method/evidence, independent-absence scope, and immutable ABI authority as one
  decision-complete input.
- Rejected alternative: treat an operator log, deletion exit status, or unset
  placeholder as a valid receipt or completed disposal.
- Status: database due inventory `DECISION_COMPLETE_R6D`; completion receipt
  `OPERATOR_OWNED_DEFERRED`, with the system completion claim `OPEN_FAIL_CLOSED`.

## SPEC-CONFLICT-022 — Six R6d commands lack an authoritative exact HTTP replay and error contract

- Affected operations: `classifyEntityPersonhood`,
  `attestEntityMaterialUseClosure`, `attestOrganizationOfficialChannel`,
  `revokeOrganizationOfficialChannel`, `createPrivacyCorrectionPlan`, and
  `transitionRetentionRequest`.
- Replay authority gap: `specs/product/addendum-command-semantics.yaml` remains
  `REVIEW_REQUIRED` and does not close the deployment/actor/session scope, the
  semantic-request preimage, safe response-header encoding, `X-Request-Id`
  behavior, replay-marker policy, persisted-tuple corruption handling, expiry
  and refresh behavior, or legacy-row treatment required for byte-identical HTTP
  replay. The current stored JSON response plus a replay-only transport marker
  cannot establish byte identity without those decisions.
- Error authority gap: the six operation rows declare `INVALID_PARAMETER` and
  `STEP_UP_REQUIRED`, but no top-level operation authority defines how those
  codes relate to request-bound Actor Assertion `RequestMismatch` failures and
  the current transport mapping. Changing the runtime mapper or the declared
  errors in either direction would choose an undeclared public contract.
- Safe implementation: preserve the current fail-closed idempotency, assertion,
  and validation behavior, but do not claim exact HTTP-byte replay compliance
  and do not change the global idempotency model or remap the two error families.
  Runtime tests may prove the currently implemented behavior only; they do not
  supply the missing authority.
- Unlock conditions: authority must define the exact scope and semantic preimage,
  persisted status/body/header tuple, safe header codec, request-ID and replay
  marker behavior, corruption/TTL/refresh/legacy rules, and operation-level error
  precedence and public codes. The resulting decision then requires fresh,
  changed, expired, corrupted, partial, and legacy replay probes for all six
  operations.
- Status: `OPEN_AUTHORITY_DECISION`; no speculative runtime or global
  idempotency change is authorized by R6d.

## SPEC-CONFLICT-023 — Legacy PERSON plaintext lacks an authoritative entity and retention mapping

- Binding boundary: D1 permits anonymization only after immutable natural-person
  classification and material-use closure receipts bind the exact
  `AGENCY|SUPPLIER` entity. Existing rows without those receipts remain staged
  legacy and fail closed; immutable publication history remains preserved.
- Current mapping gap: `core.relationship_graph_endpoints_v2` contains immutable
  PERSON plaintext but has no authoritative entity-receipt or entity-link tuple.
  The v3 person-context rows have independent retention schedules but no exact
  `AGENCY|SUPPLIER` link. Raw, source, materialized, and immutable revision
  artifacts likewise have no complete per-field erase-versus-preserve mapping to
  a classified entity and closure receipt.
- Safe implementation: do not wipe, migrate, link, or backfill any of those rows
  by name, digest coincidence, graph proximity, publication reference, or other
  inference. They remain staged legacy and unavailable to the D1 execution owner.
  The concrete live `public.agencies` and `public.suppliers` projection nulling
  fix does not rewrite immutable revision bytes and does not claim to close this
  historical mapping gap.
- Rejected alternatives: infer an entity link from a matching display name or
  identifier digest; treat a v3 context schedule as entity authority; erase all
  PERSON-shaped source or revision fields after one entity closes; or mutate
  immutable history to make the retention graph appear complete.
- Unlock conditions: authority must enumerate each legacy relation and field,
  define an exact immutable entity-link producer and evidence, bind the relevant
  classification/closure/schedule/legal-hold receipts, and state whether every
  byte is erased, cryptographically erased, anonymized, or preserved. Migration
  and negative cross-entity tests are required before any backfill or historical
  mutation is permitted.
- Status: `OPEN_AUTHORITY_DECISION`; D1 execution is limited to concretely linked
  current entity rows and does not claim legacy or immutable-history erasure.

## SPEC-CONFLICT-024 — Public contract entity references required erased plaintext

- Conflicting authority: the base Public API `EntityRef` required `name` as a
  non-null string, while the R6d D1 supervisor decision requires natural-person
  plaintext names to be removed without deleting entity IDs, digests, contract
  relationships, or immutable publication history. The active D1 event contract
  likewise requires the public projection to preserve entity identity and
  contract links while clearing only nullable plaintext fields.
- Resolved implementation: `EntityRef.name` remains a required response field but
  becomes `string|null` in the shared handwritten resource authority and both
  bound Public and Control source OpenAPI documents. A joined entity whose
  retained ID points to an anonymized agency or supplier is represented by that
  exact ID, entity type, and href with `name: null`. Direct agency and supplier
  list, detail, search, export, and coverage rows remain suppressed when their
  projected name is null.
- Rejected alternatives: remove the public contract or relationship; invent an
  anonymization label, empty string, identifier digest, or ID-derived display
  name; omit the required field; mutate immutable revisions; or publish a private
  audit digest as replacement display text.
- Resolution authority: R6d supervisor D1 plus the binding
  `entity.retention_anonymized.v1` consumer rule. Generated OpenAPI and clients
  are regenerated from the handwritten source and are not edited directly.
- Status: `RESOLVED_BY_SUPERVISOR_R6D_D1`.

## SPEC-CONFLICT-025 — Verified endpoint proof lacks a canonical verifier and runtime producer

- Binding boundary: R6d supervisor decision D3 removes the producerless document
  challenge and leaves `RESPONSE_RECEIPT|VERIFIED_ENDPOINT` as the exact privacy
  identity-proof set. The endpoint operation contracts define a one-time
  `EMAIL_LINK`, `SMS_OTP`, or `PROVIDER_SIGNED_BINDING` proof and a SERIALIZABLE
  transition that consumes one pending challenge, activates the endpoint,
  appends the immutable link event, rotates the communication-profile session,
  and writes its audit, outbox, and receipt graph atomically.
- Superseding reuse decision: R6d supervisor Q3 forbids a new cryptographic,
  delivery, replay or BFF handoff scheme. A future producer must reuse the
  existing envelope/assertion key-ring wiring in `crates/auth/src/envelope.rs`,
  `crates/auth/src/assertion/service.rs`,
  `services/submission-api/src/config.rs`, and
  `services/submission-api/src/state.rs`; the typed notification delivery path
  and immutable `ops.outbound_delivery_receipts` consumer in
  `services/notification-worker/src/notification_typed_delivery_body.rs`; the
  request-bound assertion and idempotency guards in
  `services/submission-api/src/routes/request_binding.rs` and
  `services/submission-api/src/routes/idempotency_binding.rs`; and the existing
  submission-session exchange/handoff in
  `apps/public-web/src/routes/submission-token-exchange.ts` and
  `apps/public-web/src/lib/server/privacy-request-bff.ts`.
- Reuse boundary: those components supply key rotation/verification, immutable
  provider-delivery evidence, single-request replay protection and scoped session
  handoff patterns. They do not authorize a new endpoint challenge token,
  canonical preimage, mailbox-possession conclusion or provider signed-claim
  mapping. No raw `EndpointVerificationProof` bytes may be reinterpreted merely
  because an existing HMAC helper is available.
- Missing canonical authority: the closed JSON variants specify only field shape
  and length. No active authority defines secret normalization, the exact byte or
  canonical-JSON preimage, hash or HMAC domain separation, verifier-key identity
  and version, or constant-time comparison for `challenge_hash`, `nonce_hash`,
  `verification_binding_digest`, and `proof_digest`. EMAIL also lacks an exact
  issuing delivery receipt and challenge/endpoint/session verifier binding.
  Provider-signed binding lacks the trusted provider configuration/key revision,
  signature/token verification, issuer, audience, nonce, expiry, and signed-claim
  mapping required to authenticate the submitted binding token.
- Remaining physical gaps:

  1. No canonical endpoint-challenge preimage, tag issuer API or persisted
     verifier `kid`/revision binds the stored challenge to the reused key ring.
     The existing endpoint-identity HMAC revision is not challenge-verifier
     authority.
  2. The typed delivery worker requires an authorized communication intent,
     rendering, provider configuration/preflight, budget and delivery aggregate.
     No endpoint-link owner/event constructs that exact upstream graph; legacy
     subscription email bookkeeping is mutable and is not an immutable delivery
     receipt substitute.
  3. `intake.communication_endpoint_verifications` stores pending/terminal digest
     fields and lineage, but the migration tree has no implemented
     `intake.request_communication_endpoint_link` or
     `intake.verify_communication_endpoint_link` owner, closed composite inputs,
     or durable endpoint-link idempotency owner. The Submission API boundary in
     `services/submission-api/src/service/addendum.rs` now rejects both
     `requestCommunicationEndpointLink` and `verifyCommunicationEndpointLink`
     before parsing raw endpoint or proof bytes. It therefore cannot synthesize
     either a `PENDING_VERIFICATION` request result or an `ACTIVE` verification
     result and is not a receipt producer.
- Safe resolution: retain the implemented `RESPONSE_RECEIPT` privacy proof
  pipeline. A privacy request naming `VERIFIED_ENDPOINT` succeeds only when an
  independently authoritative, current verified endpoint receipt already exists;
  because no such runtime producer exists, both endpoint request and verification
  operations and the dependent public flow remain `OPEN_FAIL_CLOSED`, with no
  synthetic pending challenge, ACTIVE endpoint, or proof receipt. The identified
  key-ring, typed-delivery, assertion/idempotency and scoped-session components
  are reuse targets only; none currently supplies the missing mailbox-possession
  or provider-binding authority to the Submission API owner.
- Rejected alternatives: SHA-256 or HMAC the raw token with an invented preimage;
  compare OTP or email tokens directly; trust caller-authored provider or digest
  fields; accept event presence as signature proof; or implement the declared
  transaction while omitting exact secret verification and immutable producer
  lineage.
- Unlock conditions: authority must close the three gaps above while directly
  binding the existing reusable components: a versioned per-kind verifier ABI,
  canonical preimages and persisted key/configuration revisions; an endpoint-link
  intent/rendering/delivery materializer whose EMAIL proof consumes the existing
  immutable typed delivery receipt; provider signature issuer/audience/nonce/
  expiry verification and replay binding; implemented request/verify owners and
  closed composite receipt fields; and secret-redacted errors/observability.
  Positive, malformed, cross-binding,
  expiry, attempt-limit, replay, concurrency, and redaction probes must pass
  before `VERIFIED_ENDPOINT` production is enabled.
- Status: `RESPONSE_RECEIPT` privacy authority and Q3 reuse topology
  `DECISION_COMPLETE_R6D`; `VERIFIED_ENDPOINT` producer remains
  `OPEN_FAIL_CLOSED` on the three enumerated physical/ABI gaps. No new crypto or
  synthetic delivery receipt is authorized.

## SPEC-CONFLICT-026 — PUB-031 lacks a server-only privacy proof handoff

- Binding boundary: the active UI action contract places
  `createPrivacyRequest` and receipt exchange in PUB-031 `rights`, with
  `subjectIdentityProof`, abuse proof, and receipt token sourced only from
  `request_context.server_only_exchange_input` and never rendered into the
  browser. Successful exchange alone may create the path-scoped, host-only
  privacy receipt session used by `getPrivacyRequest`.
- Current reachability gap: the `/privacy` screen descriptor exposes only two
  local navigation actions and the policy GET. The server-only
  `createPrivacyRequestWithServerProof` seam has no production caller, so create
  and exchange are unreachable and the status cookie cannot be established by
  that page. The effective UI contract still marks the handler
  `OPEN_IMPLEMENTATION`.
- Missing handoff authority: no operation, session lineage, or cookie contract
  converts an existing proof into the exact server-only privacy input.
  `RESPONSE_RECEIPT` is a response-portal session scoped to `/respond/receipt`,
  not a transferable `receiptId` plus possession token at `/privacy`.
  `VERIFIED_ENDPOINT` has neither the producer closed in SPEC-CONFLICT-025 nor a
  receipt-to-privacy handoff. The privacy route deliberately rejects query-token
  transport.
- Safe resolution: preserve the strict two-kind BFF shape validator, the
  Submission API and database `RESPONSE_RECEIPT` pipeline, and the scoped status
  reader, but do not expose a form action that can only manufacture or accept a
  browser-authored proof. PUB-031 create/exchange remains
  `OPEN_FAIL_CLOSED`; absence of a proof source returns no synthetic success and
  performs no Submission API call.
- Rejected alternatives: widen or share the response-portal cookie path; copy a
  host-only cookie across applications; place possession, endpoint, or receipt
  tokens in a URL, DOM, hidden form, browser storage, or redirect; infer privacy
  proof from a scoped session; or make an unusable action appear enabled while
  always substituting a placeholder proof.
- Unlock conditions: authority must define the proof-producing operation and
  issuer, exact server-to-server handoff payload, single-use/expiry/replay rules,
  origin and cookie isolation, proof consumption and session rotation, error
  precedence, and the PUB-031 form/action state contract. End-to-end tests must
  prove both accepted proof kinds, cross-scope rejection, no browser exposure,
  exact receipt exchange, and status-cookie recovery before the handler is
  marked implemented.
- Status: server validation and persistence seam `IMPLEMENTED_FAIL_CLOSED`;
  public proof handoff and PUB-031 create/exchange
  `OPEN_AUTHORITY_DECISION` / `OPEN_IMPLEMENTATION`.

## SPEC-CONFLICT-027 — NAMED_INDIVIDUAL manual-producer scope was over-read

- Apparent conflict: an earlier audit read R6d T2's
  `legal_risk_flags contains NAMED_INDIVIDUAL` condition as requiring a second,
  reviewer-authored finding producer in addition to the approved text scanner.
  Neither T2 nor supervisor decision Q2 defines such a producer. Q2 instead
  makes the scanner the finding producer and makes the independent human legal
  review the producer of the exact, immutable override receipt.
- Active resolution: preview, publish, and correction publication scan the
  complete public-text payload and persist immutable findings. A detected name
  blocks publication unless the exact current snapshot, public-text digest,
  ruleset, registered-name set, and finding set are covered by the two-stage
  review path and a restricted
  `PUBLIC_FIGURE|OFFICIAL_DISPOSITION_QUOTE` override receipt. The derived
  `legalReviewed` value comes only from that current receipt; no caller boolean,
  case-level `legal_review_required` flag, or free-form review summary can grant
  publication authority.
- Scope boundary preserved: no manual flag is inferred or synthesized. If a
  future authority introduces reviewer-authored `NAMED_INDIVIDUAL` findings, it
  will require a separately specified producer and currentness contract, but
  that unrequested future surface does not make the approved scanner path
  incomplete.
- Rejected alternatives: treat `legal_review_required` as a finding; accept a
  caller-authored `legal_reviewed` boolean; let ordinary editorial approval clear
  a scanner finding; or reuse an override after any bound payload, snapshot,
  ruleset, registered-name set, or finding-set change.
- Status: `RESOLVED_R6D`; the scanner-derived protection and immutable human
  override path are the complete T2 authority. A separate manual finding
  producer is outside the approved R6d scope and remains nonexistent.

## SPEC-CONFLICT-028 — Additive migration executor provenance is not executable

- Binding boundary: `specs/database/addendum/global.yaml` forbids execution of
  migrations 0025 through 0039 by `postgres`, a database owner, a superuser, or
  a runtime role. Every transaction must authenticate as
  `gurine_migration_executor`, prove the bounded SET-only membership and DDL
  lease, then `SET LOCAL ROLE gurine_migrator`; the deployment controller must
  also perform the checksummed base-owner adoption and unconditional lease
  close.
- Current physical state: none of migrations 0025 through 0039 contains the
  required executor-role transition. Migrations 0037, 0038, and 0039 enter
  product SQL immediately after their outer `BEGIN`, while repository runtime,
  SQLx, backup/restore, and flow helpers still apply the migration set through
  `psql -U postgres`. The migrator runtime has no implemented adoption or
  bounded lease controller that can replace those helpers.
- Conflicting authority: the registered transaction-profile rule requires the
  immutable 0030 migration to retain its byte-pinned 29 balanced
  `BEGIN`/`COMMIT` blocks and historical tail, while the cross-file requirement
  separately requires replacing 0030's self-contained transaction control with
  one outer executor transaction. Both cannot be implemented byte-for-byte.
- Safe resolution: do not add a partial preamble to 0038 or 0039 and do not
  represent a postgres-applied disposable migration run as executor-provenance
  evidence. Functional PostgreSQL probes may continue to diagnose product SQL,
  but they do not satisfy the deployment or `verify-final` authority boundary.
- Rejected alternatives: patch only the two R6d migrations; silently fall back
  from `MIGRATOR_DATABASE_URL` to a bootstrap URL; authenticate as postgres and
  spoof SQL-visible identities; invent the adoption manifest, lease predicate,
  network fence, secret flow, watchdog, or provenance artifact; or select one
  of the incompatible 0030 transaction rules without supervisor authority.
- Unlock decisions: select the authoritative 0030 transaction profile and
  provide the exact checksummed adoption, lease-open/close, network-fence,
  ephemeral-secret, watchdog, and provenance artifact contract. Then implement
  and rehearse the complete 0025-through-0039 path and replace every postgres
  migration helper together, including a postgres negative canary.
- Status: `OPEN_AUTHORITY_DECISION`; current R6d PostgreSQL runs are functional
  SQL evidence only, and no migration-executor or final-readiness claim is made.

## SPEC-CONFLICT-029 — Base Public API problem type URI has no value authority

- Binding boundary: the final Public API OpenAPI schema requires every
  `ProblemDetails` response to contain `type`, `title`, `status`, and
  `requestId`; `type` must be a URI reference. The final base error catalog is
  the sole authority for error status, title, retryability, and exposure, but it
  does not assign a problem type URI or a URI derivation rule.
- Runtime finding: the Public API `problem` and export-limit response builders
  omit `type`. R6d intentionally keeps the privacy policy and terms of use
  unpublished until the user-owned organization and external-review fields are
  supplied, so their current fail-closed `STORAGE_FAILURE` 503 responses expose
  this mismatch in the PostgreSQL Public API flow. Strict OpenAPI validation
  fails because the response has no `type` member.
- Conflicting candidate authority: RFC 9457 permits `about:blank`, while the
  owner addendum proposes a code-derived absolute URI template. That addendum
  is `REVIEW_REQUIRED`, scopes its RFC 9457 contract to additive and private
  operations, and explicitly does not change the v13 base authority. It cannot
  silently assign a value to base Public API operations.
- Safe resolution: preserve the legal-document fail-closed response and the
  strict runtime schema assertion. Do not insert `about:blank`, extend the
  addendum template to base operations, make `type` optional, skip 503 response
  validation, or publish a draft legal document merely to avoid the error path.
- Unlock decisions: select the exact base problem-type URI rule and its scope
  across Public, Control, Submission, and Identity APIs; define code
  normalization and stability/versioning; then update every affected response
  builder, typed contract/example, and positive/negative runtime test together.
- Status: `OPEN_AUTHORITY_DECISION`; Public API success and export paths remain
  implemented, but the full Public API flow is a failing sensor at the first
  intentionally unpublished legal-document 503 until this response contract is
  decided.

## SPEC-CONFLICT-030 — Response-submission reciprocal FK blocks the required async lifecycle

- Binding boundary: the active response-submission state and command contracts
  require `submitResponse` to commit an immutable submission, receipt, and three
  v2 outbox events first. A later workflow transaction consumes
  `workflow.response_submitted.v2`, creates the editorial response, and writes
  the reciprocal owned-intake tuple atomically.
- Conflicting database authority: the active 0027 database addendum and migration
  0038 require `response_submissions_editorial_response_reciprocal_fk` to be an
  eight-column `MATCH FULL` foreign key. Four source columns (`id`,
  `response_request_id`, `receipt_version`, and `receipt_digest`) are non-null at
  submission time, while `editorial_response_id` and the three owned-intake
  columns must remain null until the later materializer transaction.
  PostgreSQL rejects that mixed-null tuple at commit. `NOT VALID` skips only the
  historical scan and does not exempt new writes.
- Runtime finding: after the R6d event-consumer fixture supplied the exact 0038
  legacy v1 receipt digest, PostgreSQL failed the new submission insert with
  `MATCH FULL does not allow mixing of null and nonnull key values`. The actual
  Submission API calls `intake.submit_response_session_v3` as one autocommit
  SQLx statement, so the production path reaches the same failure before the
  asynchronous materializer can run. The control fixture hides the defect by
  invoking submit and materialize in one artificial transaction, while the R6d
  authority fixture disables FK triggers for its rollback-only source seed.
- Supervisor resolution: the pre-resolution 0027 contract required both
  reciprocal foreign keys to use `MATCH FULL`, but that shape is structurally
  incompatible with the required two-commit lifecycle. The active 0027 contract
  now specifies `MATCH SIMPLE DEFERRABLE INITIALLY DEFERRED` and explicit
  zero-or-all checks. Migration 0039 forward-recreates both reciprocal foreign
  keys as `MATCH SIMPLE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED NOT
  VALID`, without rewriting migration 0038.
- Equivalent protection transfer: `MATCH SIMPLE` may skip a tuple containing a
  null source column, so 0039 moves the protection formerly supplied by
  `MATCH FULL` into explicit database checks. The submission ownership fields are
  either all null or all non-null. The editorial origin fields are likewise all
  null or all non-null, and the complete branch additionally requires a non-null
  `response_request_id`. Once complete, the paired eight-column foreign keys,
  unique bindings, and `ON DELETE RESTRICT` enforce the same submission, request,
  receipt, response, outbox-envelope, and owned-intake digests in both directions.
- Materializer transaction rule: the 0039 materializer wrapper explicitly sets
  `editorial_responses_submission_reciprocal_fk` and
  `response_submissions_editorial_response_reciprocal_fk` to `DEFERRED` before
  invoking the existing owner. This preserves the cyclic response insert plus
  submission update even when a caller previously selected `IMMEDIATE`; both
  constraints are still checked no later than transaction commit. The wrapper
  also copies the event-bound `response_request_id` into the existing
  transaction-local `gurine.response_request_id` RLS context before the private
  SECURITY DEFINER owner reads `intake.response_submissions`. Without that
  binding the owner runs as `gurine_migrator`, sees no RLS-visible row, and
  falsely reports `response_materialization_submission_mismatch` even when the
  submission, event, and receipt tuples are byte-identical.
- Rejected alternatives: weaken or remove only one FK; omit the explicit shape
  checks or the `response_request_id` binding; make ownership
  mandatory in the submit transaction; co-locate the asynchronous materializer
  with submission; use replication-role bypass in production; split the tuple
  and lose cross-row identity coherence; or encode the current failure as an
  accepted runtime result.
- Verification obligation: PostgreSQL runtime evidence must cover the independent
  unmaterialized submission commit, later materialization under caller-selected
  `IMMEDIATE`, partial/mismatched/one-sided tuples, exact and changed replay,
  delete restriction, stale races, and two- and 64-consumer convergence. Fixture
  setup that temporarily disables triggers is not evidence for the production
  submission boundary.
- Status: `RESOLVED_BY_SUPERVISOR_R6D`; the forward-only 0039 implementation and
  active 0027 contract carry the approved `CHECK + DEFERRED` equivalent
  protection.

## SPEC-CONFLICT-031 — D1 governance capability and independence comparator resolved

- Binding boundary: supervisor-final D1 requires both entity-governance
  decisions to be performed by a request-bound human holding `users.manage`
  under STEP_UP. Classification independence is exactly human versus
  automation; it does not create a second per-command maker-reviewer actor.
- Closure separation: material-use closure has one additional two-stage
  invariant. Its `actor_id` must differ from the `actor_id` stored on the exact
  referenced NATURAL_PERSON classification receipt. No source-producer,
  represented-subject, or other inferred comparator is introduced.
- Database enforcement: forward migration 0040 locks and validates the exact
  classification receipt, then compares `p_actor_id` with
  `v_personhood.actor_id` before material-use calculation or writes. Equality
  raises SQLSTATE `55000` with exact message
  `r6d_entity_closure_actor_not_independent`; Control maps that pair through the
  owned database boundary to typed `PRECONDITION_FAILED` (422), and the whole
  command writes no closure receipt, audit, outbox event, or entity pointer.
- Capability resolution: `sources.operate` remains limited to ingestion,
  schema, and backfill operation. Assertion, role grant, authority digest,
  audit, and STEP_UP bindings for both D1 commands use `users.manage`.
- Preserved safeguards: both receipts remain human-only, immutable,
  public-source-bound, and fail closed for staged legacy rows. Migration 0039
  remains immutable history; 0040 is the forward-only correction.
- Status: `RESOLVED_BY_SUPERVISOR_R6D_D1_FINAL`.

## SPEC-CONFLICT-032 — Response materialization event had no runtime consumers

- Binding boundary: the active event contract assigns
  `editorial.response_materialized.v2` to exactly two logical consumers,
  `submission-projector` and `audit-indexer`, both hosted by the physical
  `projection-worker`. Delivery and replay identity remain
  `(consumer,event_id)`; plaintext response, party-name, consent, endpoint, and
  token material are forbidden from both consumer results.
- Runtime finding: the 0038 materializer emitted the registered v2 event, but
  the scheduler catalog had no matching route. The scheduler therefore marked
  the outbox row published while creating no inbox or delivery job. The lower
  priority consumer catalog also omitted both v2 bindings, and the projection
  worker rejected the event even if a job was supplied manually.
- Active resolution: the scheduler now creates exactly two logical inbox rows
  and two physical projection-worker jobs. Both handlers verify the immutable
  outbox envelope, validate the exact 14-field digest-only payload and closed
  party/identity shape, persist a consumer-specific JSON result in
  `ops.inbox.result`, and return that identical stored result on exact replay
  with no response, audit, or outbox mutation. The lower consumer catalog is
  aligned to the same two bindings.
- Rejected alternatives: treat zero consumers as success; route the event to
  the workflow queue; acknowledge an unknown event; create a speculative second
  response projection table; grant the projector access to encrypted response
  bodies or party names; or store only a generic `SUCCEEDED` marker that cannot
  prove deterministic replay.
- Status: `RESOLVED_R6D_RUNTIME`; the event-consumer smoke owns the exact route,
  completion, stored-result replay, and owner-graph zero-mutation oracle.

## SPEC-CONFLICT-033 — Global actions.review authority exceeds the executable seed

- Authority statement: the additive authorization catalog in
  `specs/product/owner-addendum-2026-07-14.yaml` assigns `actions.review` to
  `SECURITY_ADMIN`.
- Runtime seed and enforcement: `db/migrations/0005_roles_grants_and_seed.sql`
  grants `kill_switch.execute` to `OPERATIONS`, `SECURITY_ADMIN`, and
  `EXECUTIVE_APPROVER`, but the final additive seed in
  `db/migrations/0030_v13_submission_session_hardening.sql` grants
  `actions.review` only to `LEGAL_REVIEWER`, `OPERATIONS`, and
  `EXECUTIVE_APPROVER`. Provider-control reviewer selection requires both
  `actions.review` and the operation's required capability, and the claim and
  decision paths recheck `actions.review` against the selected role.
- F5 provider-control resolution: do not expand authorization.
  `specs/product/addendum-approval-policy.yaml` and the executable lifecycle
  validator now declare the actual capability intersection: `OPERATIONS` and
  `EXECUTIVE_APPROVER` for the three `kill_switch.execute` operations, and
  `OPERATIONS` for `testProviderConnection` (`jobs.operate`). Provider-control
  declaration and enforcement are therefore aligned.
- Rejected alternative: grant `actions.review` to `SECURITY_ADMIN` merely to
  make the broader global authority declaration reachable.
- Scope boundary and required follow-up: removing `SECURITY_ADMIN` from the
  global `actions.review` authority also affects non-provider ROLE_GRANT,
  KILL_SWITCH, CAPABILITY_ACTIVATION, and COMMERCIAL_CONTROL reviewer policies.
  Their complete runtime policy must be reconciled in an owner-approved
  authority revision rather than silently changed in F5. Until then, the
  PostgreSQL capability seed remains fail-closed.
- Status: `RESOLVED_F5_PROVIDER_CONTROL_OPEN_GLOBAL_AUTHORITY`; the provider
  contract is aligned without a capability grant, while the broader additive
  authorization conflict remains explicit.
