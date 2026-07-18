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
