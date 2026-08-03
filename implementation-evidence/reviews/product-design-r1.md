# Gurinnae Product Design and Information Architecture Review R1

DESIGN_VERDICT: CHANGES_REQUIRED

ROLE: PRODUCT_DESIGN / INFORMATION_ARCHITECTURE

REVIEW_MODE: DESIGN_GATE

REVIEWED_AT_UTC: 2026-07-15T02:04:24Z

REVIEW_POLICY: Independent read-only review. This artifact records findings only;
no source, specification, route, component, state, or operation contract was
modified by the reviewer.

## Reviewed snapshot

- Git commit: 0f7c7bed625d8e0b55e285285c218cb05e0957ef
- Worktree: DIRTY, 50 porcelain entries before this review artifact was added.
- Pre-artifact worktree-status SHA-256:
  2193784235bbd335ff57c783191f82f6c979f7c7ee938665951a3f5551a9fd35
- implementation-evidence/design-screen-closure.yaml SHA-256:
  067717f75a97624175c89d33b4b869ef387a3a2f99d225523bc4e2afc27eeff8
- specs/ui/navigation-action-contracts.yaml SHA-256:
  289d43ad1c0a2d2548554045233e19e0f657c0902945e71bc3c37dfb95cefedc
- specs/ui/state-profile-contracts.yaml SHA-256:
  8b22cdfcfa8413b36af372d0671dc4c2915095ab079ca45731dffa2a36c2527c
- specs/ui/screen-catalog.yaml SHA-256:
  e2dc57a4b6092105b088b84723456037bf2892f168afd542056c23284e6bff2b
- specs/product/addendum-operation-contracts.yaml SHA-256:
  d032a0c2afe1e379a7d4e1a6f7659581643fe237468a9da89a2c59f7e61f6539

The repository design-bundle digest is not asserted here. The current digest
script does not include every newly added normative database fragment, so its
output cannot identify the complete current design authority. The individual
reviewed-file hashes above identify this product-design review snapshot.

## Scope and method

The audit covered all 94 fixed screens, 496 sections, 250 screen actions, all
102 navigation actions, the nine base state profiles, the 319 declared
screen-specific state occurrences, component assignments, token-free routes,
and journeys J-01 through J-09. The evaluation criterion was whether a
representative user can immediately identify object, state, material answer,
evidence, uncertainty, and next safe action across compact, medium, and wide
layouts without an implementer having to invent behavior.

Read-only measurements:

- 94 screens and 496 section mappings are present.
- 250 screen actions are present: 102 navigation and 148 non-navigation.
- Zero non-navigation action contracts define section ownership, typed request
  binding, state-specific availability, or an exact success destination.
- All 25 owner-addendum COMMAND operations have section bindings, but zero are
  referenced as a screen action operation_id.
- Only PUB-002, INT-003, PUB-004, and CAS-004 have owner-authored exact typed
  screen slices. The other 90 screens use generated field selection.
- 319 special-state occurrences exist across 87 screens, but no special-state
  trigger/copy/preservation/action/focus registry exists.
- Twenty-one screens place all six ten-second answers in one section; 75 of 94
  use at most two sections for all six answers.
- Every one of the 94 evidence answer patterns contains the same broken
  sentence join and unconditional exact-locator promise.
- The 94 screens reuse only ten compact, ten medium, and ten wide layout
  descriptions.

## P0 blockers

### PD-R3-001 — The 94-screen closure is generated population, not semantic closure

Severity: P0

Affected journeys and screens:

- J-01 through J-09.
- Directly demonstrated by AUTH-004, PUB-006, REV-002, RSP-006, and OPS-006.
- Structurally affects the other 85 non-owner-typed screens.

Evidence:

- specs/product/owner-addendum-2026-07-14.yaml:719 declares exact typed slices
  for only four screens.
- scripts/generate_design_screen_closure.py:143 selects section fields by
  component/section keyword and rotates arbitrary safe fields as fallback.
- scripts/generate_design_screen_closure.py:282 builds the screen field pool
  from base screen data requirements before additive operation responses are
  considered.
- scripts/generate_design_screen_closure.py:439 adds owner operations to an
  operation list and section-name list, but not to the section source-field
  model.
- scripts/validation/design.py:689 validates component/surface, a non-empty
  source list, and token substrings, but not whether the fields can answer the
  section's user job.
- implementation-evidence/design-screen-closure.yaml:15077 maps every AUTH-004
  ten-second answer to status/startOidcLoginReceipt.
- implementation-evidence/design-screen-closure.yaml:15110 maps AUTH-004
  status, draft, sign-in, and support to the same startOidcLoginReceipt.
- implementation-evidence/design-screen-closure.yaml:23652 lists
  getActionProposal on REV-002 sections while the actual source slices remain
  ReviewSnapshotResponse fields.

Root cause:

The closure generator treats non-empty, display-safe field names as proof of a
screen view model. It does not encode a screen-specific required-information
set or prove that additive response schemas supply the added capability.

Required design change:

Replace heuristic/fallback slice generation with one decision-complete screen
contract per route. Each section must name the exact validated source fields
that answer its user question, including additive query/command result fields.

Acceptance evidence:

1. A validator proves set equality between each section's required semantic
   fields and its typed view-model fields.
2. Removing any required object identity, state, freshness, blocker, evidence,
   uncertainty, owner, deadline, consequence, or receipt field makes the
   corresponding screen contract fail.
3. No source selection path uses keyword matching, rotating fallback, whole
   response DTOs, raw JSON, or generic non-empty acceptance.
4. All 94 rows pass an independent semantic review with realistic non-empty
   examples.

### PD-R3-002 — Owner-addendum approval/action commands are not reachable UI actions

Severity: P0

Affected journeys and screens:

- J-03, J-05, J-06, J-07, J-08, and J-09.
- CAS-006, CAS-007, CAS-009, CAS-011, CAS-015, RULE-004, REV-002,
  REV-003, OPS-003, OPS-005, OPS-006, ADM-002, INT-002, INT-004,
  COR-001, CAS-008, PUB-030, and PUB-031.

Evidence:

- specs/product/addendum-operation-contracts.yaml:597 binds the additive
  operations only to sections.
- scripts/generate_design_screen_closure.py:509 constructs action contracts
  only from the base screen-catalog actions.
- scripts/validation/design.py:772 requires equality only with those existing
  catalog action IDs and never requires additive COMMAND-to-action coverage.
- implementation-evidence/design-screen-closure.yaml:23842 exposes
  submitReview as REV-002's approval/change-request action.
- implementation-evidence/design-screen-closure.yaml:24038 lists the new
  submitActionDecision only as an operation, with no visible action or request
  binding.
- implementation-evidence/design-screen-closure.yaml:31856 lists proposal
  preview/create/update/submit operations on OPS-006 sections.
- implementation-evidence/design-screen-closure.yaml:31952 still exposes a
  fixed direct activateKillSwitch primary action.

Root cause:

The addendum introduced a new exact-digest proposal/review/execution spine but
the screen catalog and action registry were not migrated to it. The old direct
effect actions remain while the new commands are declaration-only.

Required design change:

Every user-invoked owner-addendum COMMAND must own a visible action or an
explicit non-interactive producer contract. A visible action must define its
section, exact request source, state availability, consequence, assurance,
receipt, and success/recovery destination. Old direct-effect actions must not
provide a side door around the proposal/quorum path.

Acceptance evidence:

1. Set equality between user-invoked COMMAND operations and action contracts.
2. Each action has exact field bindings, including proposal/assignment IDs,
   expected versions/digests, decision discriminator, reason, and idempotency.
3. Action state tables cover loading, blocked, stale, conflict, reauth,
   submitting, receipt, partial failure, and terminal states.
4. Negative journey tests prove that no direct legacy action can create the
   same side effect before current approval/quorum.
5. The action's receipt and next destination are deterministic and focusable.

### PD-R3-003 — CAS-011 cannot present a typed, evidence-grounded AI investigation

Severity: P0

Affected journeys and screens:

- J-06 Investigation and the AI proposal-to-human-decision path.
- CAS-010, CAS-011, CAS-004, CAS-006, CAS-007, REV-002, and OPS-005.

Evidence:

- specs/api/resource-schemas.yaml:429 defines AgentRun.
- specs/api/resource-schemas.yaml:467 defines output as a nullable string.
- specs/api/resource-schemas.yaml:471 defines citations as UUID values without
  locator/revision/provenance.
- specs/api/resource-schemas.yaml:476 defines unknowns, but the screen closure
  does not map them to the ten-second uncertainty answer.
- implementation-evidence/design-screen-closure.yaml:21045 maps
  unknown_or_disputed to the identity section and omits AgentRun.unknowns.
- implementation-evidence/design-screen-closure.yaml:21139 renders output with
  StructuredContentSection from one opaque output field.
- implementation-evidence/design-screen-closure.yaml:21157 renders citations
  with StructuredContentSection rather than evidence/locator interaction.
- implementation-evidence/design-screen-closure.yaml:21275 exposes
  accept-suggestion without a screen-level suggestion selector, version,
  digest, target, or effect binding.
- specs/ui/component-catalog.yaml:50 already defines AgentSuggestionPanel with
  objective, evidence scope, suggestion, citations, unknowns, cost, and
  accept/reject reason, but CAS-011 does not use it.

Root cause:

The v13 generic AgentRun string/UUID projection was retained while the new
typed proposal, tool, citation, and action model was added elsewhere. The UI
has no discriminated AI result view model and therefore cannot format what was
searched, found, disputed, or proposed.

Required design change:

Define a typed AgentRunDetailVM and proposal collection for every declared
agent. It must separate verified evidence, research artifacts, tool steps,
findings, counter-evidence, unknowns, limitations, next investigation tasks,
cost, and action drafts. Each proposal must be independently selectable and
digest-bound.

Acceptance evidence:

1. No CAS-011 view model contains an opaque output string or raw JSON.
2. Every citation opens the exact authorized asset revision and canonical
   locator, with restricted/stale/hash-mismatch states.
3. Unknowns and counter-evidence are visible adjacent to findings.
4. Tool use is shown as concise source-grounded activity/receipts, never hidden
   chain of thought.
5. Accept/reject creates exactly one typed target and shows its reason,
   version, digest, consequence, and durable receipt.
6. Proposed external communication opens exact content, recipient, channel,
   cost, risk, and approval requirements before any decision.

### PD-R3-004 — Right-of-reply submit, supplement, and appeal flow is not closed

Severity: P0

Affected journeys and screens:

- J-03 Right of reply and the J-06 to J-03 to J-06 handoff.
- RSP-002 through RSP-008 and CAS-008.

Evidence:

- specs/ui/screen-catalog.yaml:5299 states that RSP-005's job is to review and
  explicitly submit.
- specs/ui/screen-catalog.yaml:5362 defines the real answer-submit action.
- specs/ui/screen-catalog.yaml:5422 instead fixes change-answer as the primary
  action.
- implementation-evidence/design-screen-closure.yaml:13232 therefore tells
  the user that the next action is editing, not submission.
- specs/ui/navigation-action-contracts.yaml:1037 resolves
  submit-supplement only to the same RSP-006 receipt page's next anchor with
  SUPPLEMENT_GUIDANCE_ONLY.
- implementation-evidence/design-screen-closure.yaml:13733 contains only
  receipt-download and supplement-guidance action contracts.
- implementation-evidence/design-screen-closure.yaml:13819 lists
  createResponseAppeal and getResponseAppeal without an appeal form/action.
- implementation-evidence/design-screen-closure.yaml:13850 requires appealId
  for getResponseAppeal, but RSP-006 has no route parameter or typed selected
  appeal source.

Root cause:

Primary action was treated as a screen-wide constant rather than a task-state
decision. Appeal operations were attached to a generic next section without
adding the input, submission, receipt, or status interaction.

Required design change:

Make RSP-005's primary action state-dependent: submit when ready, and the first
blocking correction when not ready. Add an actual scoped appeal flow, or
remove the unsupported capability claim. Supplement guidance and appeal must
be distinct.

Acceptance evidence:

1. Ready RSP-005 exposes 답변 제출 as the only dominant action.
2. Missing answer, scan-pending, consent, authority, stale draft, conflict,
   offline, submitting, and duplicate-submit states each have exact safe action
   behavior.
3. Successful submission deterministically reaches RSP-006 with a durable
   server receipt and focus on the receipt heading.
4. Appeal input, attachments, attestation, privacy consent, submit receipt,
   current status, terminal decision, and safe return are all represented by
   typed screen actions and scoped-session bindings.
5. RSP-006 never labels a help anchor as submission.

### PD-R3-005 — Critical journey navigation graph has missing edges

Severity: P0

Affected journeys and screens:

- J-02: PUB-004 to PUB-006.
- J-03: RSP-005 to RSP-006.
- J-07: REV-002 to REV-003.
- J-09: SRC-005 to SRC-006 and affected operational status.

Evidence:

- DESIGN.md:133 defines the route anchors and durable journey outcomes.
- DESIGN.md:145 requires connected handoffs rather than screen-local success.
- specs/ui/screens/PUB-004.md:53 lists all PUB-004 actions and contains no
  calculation-reproduction action.
- specs/ui/navigation-action-contracts.yaml:122 contains PUB-004's correction
  navigation but no target to PUB-006.
- specs/ui/navigation-action-contracts.yaml:1602 defines REV-001 to REV-002.
- specs/ui/navigation-action-contracts.yaml:1626 defines navigation back from
  REV-003 to REV-002 and onward to public, but no REV-002 to REV-003 edge
  exists.
- The audited navigation target map reported zero incoming navigation actions
  for PUB-006, REV-003, and SRC-006; RSP-006 had only its own supplement-help
  anchor.
- Non-navigation action contracts define no exact success destination.

Root cause:

The navigation registry closes declared NAVIGATION actions but does not model
post-command transitions, task-group navigation, or journey reachability.

Required design change:

Create one directed journey graph that includes normal navigation,
post-command receipt transitions, session exchange, task-group navigation,
and all recovery/terminal branches.

Acceptance evidence:

1. Automated reachability from every J-01 through J-09 entry to its durable
   outcome.
2. Every edge includes exact route, required object IDs, safe query keys,
   origin/session rule, return context, history behavior, and focus target.
3. Browser-back and stale/invalid binding tests preserve useful context.
4. Cancellation, expiry, rejection, access unavailable, conflict, and partial
   effect terminate or recover without a dead end.

### PD-R3-006 — PUB-006 does not expose the data needed for reproducibility

Severity: P0

Affected journeys and screens:

- J-02 Reporter reproduction.
- PUB-004, PUB-005, PUB-006, and PUB-014.

Evidence:

- specs/api/resource-schemas.yaml:1506 defines CaseReproducibilityResponse.
- specs/api/resource-schemas.yaml:1513 requires ruleId, ruleVersion,
  inputDigest, and resultDigest.
- specs/api/resource-schemas.yaml:1523 adds formula and roundingPolicy.
- implementation-evidence/design-screen-closure.yaml:1942 maps PUB-006
  summary only to bundle summaries.
- implementation-evidence/design-screen-closure.yaml:1963 maps inputs to
  BinaryDownload status and excluded-cohort fields, omitting the required
  rule/input/result digests.
- implementation-evidence/design-screen-closure.yaml:2088 gives both JSON and
  CSV download actions a null operation binding.
- implementation-evidence/design-screen-closure.yaml:2189 separately lists
  downloadCaseReproducibility without connecting its format/request/result to
  either download action.
- implementation-evidence/design-screen-closure.yaml:2157 describes compact
  regions named identity/coverage/metrics/records that do not match PUB-006's
  actual section IDs.

Root cause:

Generic field selection and archetype layout reuse replaced the screen's
specific reproduction contract.

Required design change:

Bind rule/version, input/result digest, formula, rounding, unit, target,
included/excluded cohort and reason, snapshot/watermark, source rights,
correction context, and download checksum to explicit sections and actions.

Acceptance evidence:

1. PUB-006 screen and each download share the same canonical data digest.
2. The user can copy rule/version/input/result digest and reproduce the
   calculation without inspecting JSON.
3. Included and excluded records, denominator, units, rounding, limitations,
   rights, freshness, and corrections remain visible in compact and wide.
4. PUB-004 reaches PUB-006 in one clear action and PUB-006 returns safely.

### PD-R3-007 — State and error UX is not executable or deterministic

Severity: P0

Affected journeys and screens:

- All 94 screens.
- Especially PUB-004, RSP-003 through RSP-007, AUTH-004, REV-002,
  REV-003, OPS-003, OPS-005, and OPS-006.

Evidence:

- specs/ui/state-profile-contracts.yaml:8 names ScreenRuntimeSignalsV1 but no
  actual type or screen-specific binding registry exists.
- specs/ui/state-profile-contracts.yaml:13 says trigger ties require
  coexistence or precedence, but the file contains no precedence/coexistence
  definitions.
- specs/ui/state-profile-contracts.yaml:125 and
  specs/ui/state-profile-contracts.yaml:150 permit partial and stale to be
  true simultaneously.
- specs/ui/state-profile-contracts.yaml:35 uses an English implementation
  state token and generic summary as visible copy.
- scripts/generate_state_profile_contracts.py:64 produces only the shared 72
  base templates.
- implementation-evidence/design-screen-closure.yaml:13389 lists RSP-005
  special states only by name.
- implementation-evidence/design-screen-closure.yaml:31935 does the same for
  OPS-006's active/pending/expired/reauth states.

Root cause:

The design defines shared state vocabulary but does not bind state signals to
screen data, resolve concurrent conditions, or define any screen-specific
state behavior.

Required design change:

Define every special-state occurrence with normative parent, typed trigger and
source, precedence/coexistence, information preserved, screen-specific copy,
available actions, retry safety, focus, and live-region behavior.

Acceptance evidence:

1. Set equality across closure special states and the special-state registry.
2. Removal of any state definition or signal binding fails validation.
3. Pairwise/declared multi-state tests cover partial+stale,
   refreshing+stale, offline+saving, conflict+reauth, session-expiring+dirty,
   and effect-may-exist+error.
4. Error copy always states affected scope, saved state, safe recovery,
   support reference, and whether retry can duplicate an effect.
5. Conflict tests preserve user input and show a readable server/user diff.

### PD-R3-008 — Sensitive token values enter ten-second and view-model sources

Severity: P0

Affected journeys and screens:

- J-03 and J-04 directly.
- PUB-027 through PUB-030 and RSP-001 through RSP-008.
- Other internal receipt screens whose next-action sources include
  receiptToken or fencingToken.

Evidence:

- specs/product/owner-addendum-2026-07-14.yaml:751 fixes token-free canonical
  routes.
- specs/product/owner-addendum-2026-07-14.yaml:762 defines one-time exchange.
- specs/product/owner-addendum-2026-07-14.yaml:768 prohibits copying a token to
  query, fragment, analytics, logs, DOM, client storage, or another origin.
- implementation-evidence/design-screen-closure.yaml:13568 includes
  ResponseReceiptResponse.data.receiptToken in RSP-006 evidence sources.
- implementation-evidence/design-screen-closure.yaml:13577 includes the same
  token in unknown/disputed sources.
- implementation-evidence/design-screen-closure.yaml:13232 includes
  submitResponseReceipt.receiptToken in RSP-005 next-action sources.
- scripts/generate_design_screen_closure.py:149 filters sensitive names only
  for section source fields.
- scripts/generate_design_screen_closure.py:408 creates ten-second source
  lists from an unfiltered field pool.
- scripts/validation/design.py:709 scans only section source fields for
  sensitive terms.

Root cause:

Sensitive-field filtering is applied after one source-selection path but not
to all view-model/ten-second sources. Receipt identity and bearer/management
authority are not represented as separate types.

Required design change:

Introduce explicit server-only secret/token types and globally prohibit them
from every screen slice, ten-second source, SSR payload, DOM, analytics,
navigation context, and client log.

Acceptance evidence:

1. A whole-closure and generated-view-model sensitive-field scan covers all
   source paths, not only section_mapping.
2. Browser HTML, hydration data, accessibility tree, analytics, URLs, referrer,
   history, and console/network logs contain no raw token.
3. Safe user-visible receipt IDs are distinct types and cannot be substituted
   for bearer, draft, management, proof, or fencing tokens.
4. Exchange success and all invalid/expired/revoked/consumed branches are
   tested on canonical token-free URLs.

## P1 blockers

### PD-R3-009 — The answer-first hierarchy and content rules remain generic

Severity: P1

Affected journeys and screens:

- All journeys.
- Explicit examples: PUB-004, RSP-005, AUTH-004, SIG-002, OPS-001, and
  OPS-004.

Evidence:

- scripts/generate_design_screen_closure.py:549 constructs all six answer
  patterns from reusable sentence templates.
- implementation-evidence/design-screen-closure.yaml:1067 gives PUB-004 a
  typed section override but matters_now still describes the status section.
- implementation-evidence/design-screen-closure.yaml:1100 puts the unknown
  answer in unknown while its sentence still describes confirmed facts.
- implementation-evidence/design-screen-closure.yaml:13180 places all six
  RSP-005 answers in answers rather than separating attachments, consent,
  authority, consequence, and submit action.
- implementation-evidence/design-screen-closure.yaml:15077 places every
  AUTH-004 answer in status and promises source revision/exact locator on an
  authentication recovery screen.
- implementation-evidence/design-screen-closure.yaml:69 demonstrates the
  repeated broken phrase ending with period-plus-Korean-subject-marker.

Root cause:

The validator checks uniqueness/non-empty text, not whether the answer sentence
matches its section, grammar, object, evidence model, or primary action.

Required design change:

Author screen-specific plain-Korean answer sentences and explicitly place
answer, adjacent uncertainty, evidence affordance, and next safe action.

Acceptance evidence:

1. Content lint detects broken sentence joins, internal-only operation terms,
   unexplained jargon, and locator promises without a locator affordance.
2. Representative users correctly state object, state, material fact,
   highest-priority unknown, evidence entry, next action, and consequence
   within the DESIGN.md usability thresholds.
3. No policy/auth/receipt/system screen invents evidence semantics it does not
   own.

### PD-R3-010 — Responsive design is an archetype string, not a screen contract

Severity: P1

Affected journeys and screens:

- All 94 screens.
- Explicit examples: PUB-004, PUB-006, RSP-006, CAS-011, REV-002, and
  OPS-006.

Evidence:

- scripts/generate_design_screen_closure.py:613 copies one compact/medium/wide
  string and one semantic-order list.
- implementation-evidence/design-screen-closure.yaml:1385 describes PUB-004
  compact layout without counter-evidence or final revision even though those
  are separate required sections.
- implementation-evidence/design-screen-closure.yaml:2157 uses nonexistent
  PUB-006 region names.
- implementation-evidence/design-screen-closure.yaml:13779 reuses a
  review-step summary-rail layout on the RSP-006 receipt screen.
- implementation-evidence/design-screen-closure.yaml:31995 uses generic
  target/blocker/criteria/reason names that do not match OPS-006 sections.
- specs/ui/screen-catalog.yaml:5417 contains RSP-005 above_fold_order, but the
  closure has no normative above-fold field.

Root cause:

Archetype layout prose was treated as sufficient proof of per-screen
responsive information architecture.

Required design change:

For every screen, define exact DOM order, grid/stack placement, sticky
behavior, collapse/drawer behavior, table conversion, and above-fold content
for compact, medium, wide, and zoom/reflow.

Acceptance evidence:

1. Exact screenshot/DOM oracles at 320x568, 768x1024, and 1440x900.
2. Reflow evidence at 200% and 400% from 1280x1024.
3. No required section/action disappears, clips, changes semantic order, or is
   obscured by sticky controls/virtual keyboard.
4. Above-fold checks prove object, state, answer, blocker/freshness, and primary
   action where applicable.

### PD-R3-011 — Accessibility focus targets are not concrete contract targets

Severity: P1

Affected journeys and screens:

- All 94 screens and all 102 navigation actions.
- High impact: RSP-005, REV-002, REV-003, OPS-006, and AUTH-004.

Evidence:

- scripts/generate_design_screen_closure.py:620 hard-codes generic focus
  target names for every screen.
- implementation-evidence/design-screen-closure.yaml:23910 targets
  rev_002__receipt_or_status_heading.
- implementation-evidence/design-screen-closure.yaml:24064 lists REV-002's
  actual manifest test IDs, which contain no such target.
- specs/ui/navigation-action-contracts.yaml:1621 gives three alternative
  arrival-focus choices rather than one deterministic target.

Root cause:

Focus behavior is prose convention detached from actual element IDs and
screen/state ownership.

Required design change:

Bind every entry, validation, conflict, receipt, navigation, dialog, drawer,
and async-completion focus transition to an existing exact element contract.

Acceptance evidence:

1. Validator set equality between focus references and rendered/testable IDs.
2. Playwright activeElement assertions for every critical state transition.
3. One live announcement per async outcome without focus stealing.
4. Dialog/drawer Escape and close restore the exact initiating element.
5. NVDA+Firefox and VoiceOver+Safari critical-journey receipts.

### PD-R3-012 — Component product semantics conflict with assigned content

Severity: P1

Affected journeys and screens:

- AI journey: CAS-011 and SIG-002.
- Approval/operations: REV-002, OPS-004, and OPS-006.
- Response review: RSP-005.

Evidence:

- specs/ui/component-catalog.yaml:11 defines AccessManagementPanel exclusively
  for user/role/capability/access review.
- implementation-evidence/design-screen-closure.yaml:31836 assigns
  AccessManagementPanel:user-detail to OPS-006 impact over users/data/jobs.
- specs/ui/component-catalog.yaml:50 defines the dedicated
  AgentSuggestionPanel anatomy.
- implementation-evidence/design-screen-closure.yaml:21139 instead uses
  generic StructuredContentSection for agent output/citations/safety/cost.
- implementation-evidence/design-screen-closure.yaml:13249 gives RSP-005
  answers and attachments the same source set.
- implementation-evidence/design-screen-closure.yaml:13310 gives consent and
  authority another identical source set.
- implementation-evidence/design-screen-closure.yaml:23677 repeats a large
  common ReviewSnapshot slice across preview, matrix, diff, and decision.

Root cause:

Surface compatibility and variant existence are validated, but component
purpose/anatomy compatibility and slice ownership are not.

Required design change:

Create a component-purpose compatibility matrix and use components that match
the section's user job. Distinct sections need distinct owned slices unless a
declared composite component owns them together.

Acceptance evidence:

1. All 496 section/component assignments pass purpose/anatomy review.
2. Component state vocabulary maps to the screen state profile.
3. Duplicate slices fail unless a documented composite contract proves why.
4. AI, evidence, approval, response, and operational impact components have
   representative content and keyboard examples for every state.

### PD-R3-013 — Canonical route and contextual navigation sources disagree

Severity: P1

Affected journeys and screens:

- J-03, J-04, J-06, and all token-exchange entry paths.
- PUB-028, PUB-030, RSP-001 through RSP-007, and CAS-002 through CAS-016.

Evidence:

- specs/product/owner-addendum-2026-07-14.yaml:751 defines token-free
  canonical routes.
- specs/ui/routes.md:38 still marks receiptId/token-bearing public routes as
  FINAL.
- specs/ui/routes.md:46 still marks all response routes as token-bearing.
- specs/ui/navigation.yaml:139 lists case-task screens without current caseId,
  safe-return, query-preservation, or focus bindings.
- specs/ui/navigation-action-contracts.yaml:1 covers 102 catalog navigation
  actions but does not close the global case-task-group route construction.

Root cause:

Route documentation, token exchange, catalog navigation, global navigation,
and task-group navigation have separate non-generated sources.

Required design change:

Use one canonical route registry to generate route index, breadcrumbs, steps,
headers, and task groups. Token URLs must exist only as exchange endpoints.

Acceptance evidence:

1. Set equality across route catalog, route docs, Svelte routes, redirects,
   breadcrumbs, navigation actions, and E2E route discovery.
2. Every case task-group link binds the current authorized caseId and exact
   safe return.
3. Token-bearing paths always exchange once and redirect with no token in the
   canonical browser state.
4. Invalid exchange never reveals object existence.

## P2 residual observations

### PD-R3-014 — Plain-language consistency needs a product glossary

Affected screens:

- All surfaces, especially PUB-004, PUB-006, RSP-005, CAS-011, REV-002, and
  OPS-006.

Evidence:

- DESIGN.md:250 requires plain Korean first and expansion of domain terms.
- implementation-evidence/design-screen-closure.yaml:1077 mixes revision and
  freshness in the primary public status answer.
- implementation-evidence/design-screen-closure.yaml:1901 mixes reason,
  revision, and exact locator in one public reproduction sentence.
- implementation-evidence/design-screen-closure.yaml:31768 exposes the
  operation-like word activate in the Kill Switch next-action sentence.

Required follow-up:

Define user-facing Korean terms for revision, claim, source, snapshot,
receipt, exact locator, blocker, freshness, and digest, while retaining the
technical term only in expandable support/audit detail.

### PD-R3-015 — Internal global navigation lacks role-relevance rules

Affected screens:

- INT-001 through ACC-001.

Evidence:

- specs/ui/navigation.yaml:101 lists the common internal navigation groups.
- specs/ui/navigation.yaml:131 applies an explicit capability rule only to the
  admin group.
- specs/ui/roles-and-permissions.yaml:254 validates action capabilities but
  does not define role-specific navigation relevance.

Required follow-up:

Keep authorization server-side, but define role-aware ordering and
discoverability so each role sees My Work and its highest-value journey before
irrelevant registries and operational tools.

## Required retest evidence

A new product-design review may return LGTM only after all PD-R3-001 through
PD-R3-013 findings are closed against one newly hashed design bundle. The
retest bundle must include:

1. The revised 94-screen semantic closure with no generator fallback.
2. A complete action registry with all additive commands and exact
   state/request/result bindings.
3. A complete special-state and precedence registry.
4. A complete journey/navigation graph and executable reachability report.
5. Typed CAS-011 AI-result/proposal examples with exact citation navigation.
6. End-to-end response submit/receipt/appeal screen contracts.
7. PUB-006 reproduction and digest-consistency examples.
8. Token-leak negative validation over all screen source paths.
9. Per-screen compact/medium/wide/zoom layout and focus oracles.
10. Representative usability protocol evidence for the designated critical
    screens; implementation/runtime evidence remains a later gate.

## Final reviewed state

- Reviewed commit: 0f7c7bed625d8e0b55e285285c218cb05e0957ef
- Reviewed worktree: DIRTY shared tree, 50 pre-artifact porcelain entries.
- Review artifact scope: this file only.
- Source/spec edits by reviewer: NONE.
- Unresolved P0 findings: PD-R3-001 through PD-R3-008.
- Unresolved P1 findings: PD-R3-009 through PD-R3-013.
- Residual P2 findings: PD-R3-014 through PD-R3-015.

DESIGN_VERDICT: CHANGES_REQUIRED
