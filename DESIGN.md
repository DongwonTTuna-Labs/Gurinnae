# Gurinnae Product Constitution

<!-- markdownlint-configure-file {"MD013": false} -->

Status: `REVIEW_REQUIRED` — open, not `FINAL`, and not implementation-approved  
Version: `0.3.0`  
Steering date: `2026-07-15`  
Base authority ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

This document fixes the product and design axis requested by the product owner. It
is a steering overlay for the hash-pinned v13 authority pack, not another Gurinnae
specification pack. It does not relax a security, evidence, publication, privacy,
accessibility, test, or operational hard gate. Conflicts are resolved only through
the precedence in `AGENTS.md` and recorded in
`implementation-evidence/spec-conflicts.md`.

The product owner's 2026-07-14 and 2026-07-15 instructions are additive steering.
Their current enumerated proposal is in
`specs/product/owner-addendum-2026-07-14.yaml` and the linked addenda. Canonical
Rust/domain ownership is in `implementation-evidence/design-domain-closure.yaml`.
Those files remain `REVIEW_REQUIRED`: a declared summary count is not a frozen
design fact until it equals the source-derived inventory and the exact design
bundle receives every required independent `LGTM`. Original v13 contracts remain
mandatory compatibility minima; no addendum contract may replace them.

## 0. Decision and review constitution

### 0.1 Truth and decision hierarchy

Apply this hierarchy from highest to lowest. A lower layer may prove or refine a
higher layer but may not silently reinterpret it.

1. The product owner's current explicit instruction defines the requested outcome
   and may add scope, but never authorizes bypassing safety, authorization,
   evidence, privacy, test integrity, destructive-action, secret-handling, or
   no-direct-merge invariants.
2. The exact v13 ZIP identified above is the only Gurinnae specification pack.
   Its bytes, `MANIFEST`, validator, and PostgreSQL baseline are immutable input;
   an earlier pack or separate Gurinnae document is not a compatibility source.
3. Inside that pack, use the precedence in `AGENTS.md` and
   `FINAL_BUILD_CONTRACT.md`. Record an actual contradiction in
   `implementation-evidence/spec-conflicts.md`; do not blend both sides.
4. Owner addenda and this constitution may extend a base contract only through
   explicit IDs, typed schemas, owners, states, persistence, operations, events,
   screens, acceptance, and a fail-closed conflict resolution. While their status
   is `REVIEW_REQUIRED`, they are proposals awaiting closure, not permission to
   improvise implementation.
5. Current source, generated contracts, migrated PostgreSQL, browser behavior,
   provider receipts, and test evidence prove conformance. They never create a
   missing product or business rule by accident.
6. Prior reviews, screenshots, plans, summaries, and superseded digests are
   provenance only. Their findings remain open until retested, but their proposed
   solution is not authority.

When a high-impact decision is absent or contradictory, use `OPEN_DECISION` when
the owner must choose between materially different products and `DESIGN_BLOCKED`
when an existing requirement lacks a decision-complete contract. Do not choose an
auth/authz, payment, legal, retention, database, public API, external-provider,
editorial, or irreversible rule on an implementer's behalf. Each open item names
the exact decision, owner, affected IDs, safe interim behavior, and executable
acceptance needed to close it. The safe interim behavior is always unavailable,
unknown, blocked, or read-only—never fabricated success.

### 0.2 Closure states

`REVIEW_REQUIRED` means the design can still change and remains the document status
while any open item, validator failure, `CHANGES_REQUIRED`, or stale role exists.
Individual review states remain the closed values in the expert status contract:
`REVIEW_IN_PROGRESS`, `CHANGES_REQUIRED`, `LGTM`, and `STALE`. `FINAL` is permitted
only when every required specialist has returned a valid `LGTM` for one identical
design-bundle digest and all prior finding IDs are closed or accepted as
non-blocking P2/P3 residual risk. Implementation completion is a later claim bound
to one clean source commit and evidence bundle; it cannot be inferred from a
`FINAL` design.

Any included design byte change invalidates `FINAL` and all prior design verdicts.
Any affected source, migration, generated-contract, fixture, test-contract,
runtime, or deployment change invalidates the corresponding implementation
verdicts. A status label, manifest entry, generated count, passing unit test,
screenshot, or reviewer prose cannot advance a state without its exact required
evidence.

### 0.3 Source-derived inventories

The enumerated IDs are authoritative; handwritten totals are assertions to verify,
not independent sources of truth.

- Base inventories are read from the hash-pinned v13 catalogs and byte-lock.
- Additive operations, commands, events, tables, state machines, schemas,
  capabilities, providers, sessions, screen actions, and acceptance cases are
  glob-sorted and counted from their canonical enumerated registries after unique-ID
  and reference validation.
- The fixed three surfaces and 94 authority routes remain base invariants. State
  occurrences, responsive variants, non-state mutations, actions, consumers,
  handlers, migrations, and additive relations are derived from the current
  closure graph; a previous review's number is never a target to preserve.
- A list and its declared count must be set-equal across owner contract, domain
  owner, API, command, persistence, event, database, UI, traceability, and
  acceptance registries. Duplicate, orphan, undocumented, or unreachable IDs fail
  validation. A count change caused by a legitimate explicit contract updates all
  consumers atomically; functionality is never hidden or merged merely to retain
  an old total.
- Validators calculate both the inventory and count. They must not pass by testing
  only a magic number, a non-empty field, a filename, or a generated fallback row.

The current physical candidate decision is
`specs/database/addendum/physical-adjudication.yaml`. Its enumerated v2 set is a
review input, not a migrated fact: 19 `NEW`, 8 `MAP`, and 2 `NONPHYSICAL`
decisions currently imply 125 additive and 232 final active relations only after
all referenced physical contracts and PostgreSQL migrations compile. Until then,
the runtime remains the source-derived 107-table base plus whatever reviewed
post-base migrations actually exist. Base migrations `0001` through `0024` are
byte-identical to the pinned ZIP in both spec and runtime directories; historical
implementation deltas belong only in `0030` or a later reviewed post-base
migration, never in a base-derivation hash exception.

### 0.4 Common product and expert prompt

The following is the stable prompt spine for designers, implementers, QA, and
independent reviewers. `<...>` values are review-run parameters, not product
placeholders; a run with an unresolved parameter is invalid.

```text
Evaluate Gurinnae against authority ZIP
960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5
and exact design bundle <DESIGN_BUNDLE_SHA256> at <SOURCE_COMMIT_OR_TREE_DIGEST>.

Objective: a person must understand the applicable object, current truth,
uncertainty, evidence and counter-evidence, investigation history, next action,
and action consequence within ten seconds, then reach the exact source or safely
complete the task without hidden interpretation work.

For every affected journey, screen, state, operation and external effect, verify:
entry and exit; accountable owner and handoff; exact typed source; visible answer
and uncertainty; immutable provenance; one safe next action or explicit NONE;
authorization and approval; persistence/event/consumer closure; error, conflict,
offline and recovery behavior; compact/wide/keyboard/screen-reader behavior;
business metric effect; operations and support; and executable acceptance.

For AI work, trace authorized Internet or multimodal input through immutable raw
artifact, parser/locator, normalized fact, snapshot/warehouse, tool/provider turn,
typed analysis, citation validation, visualization/table, human proposal and
decision, separately authorized execution, channel receipt and reconciliation.

Reject generic/fallback rendering, raw JSON UX, synthetic data or receipts,
fixture-only production paths, placeholder/TODO, 501, skipped or weakened gates,
unreachable actions, unsupported claimed channels/media, untyped JSONB, inferred
health/cost/success, stale evidence, and a declaration without runtime proof.

Return LGTM only with zero P0/P1, a retest result for every prior finding ID, and
evidence bound to this exact digest. Otherwise return CHANGES_REQUIRED with the
smallest decision-complete root-cause change and exact re-verification evidence.
```

## 1. North star

Every journey and every screen must let a person find, without interpretation
work, the current facts, what remains unknown, the supporting and contrary
evidence, what was investigated, and the next safe action. When AI proposes an
action, the person must understand the reason, scope, recipient, effect, risk, and
exact content before making only the decision that requires them.

Gurinnae is a public-procurement evidence and investigation decision system. It is
not a general ontology platform, a corruption score, an autonomous publisher, or
an unofficial personal-account messaging bot.

The product succeeds when a user can:

1. notice what deserves attention;
2. verify why with revision-fixed evidence;
3. see uncertainty, counter-evidence, and the subject's response;
4. understand what has already been checked;
5. take or approve the next bounded action;
6. return later and immediately understand what changed.

## 2. People and jobs

### Public reader, reporter, and researcher

- Understand a case without knowing internal terminology.
- Verify each material statement against its source and exact locator.
- Distinguish confirmed facts, interpretation, unknowns, and responses.
- Cite, reproduce, subscribe to, or request correction of the evidence.

### Investigator, editor, reviewer, and operator

- Triage a signal into an evidence-linked case.
- Compare contracts, entities, documents, and rule results without raw JSON.
- See incomplete, stale, conflicting, or blocked work before apparent success.
- Review AI proposals and approve only the exact external or state-changing act.
- Recover safely from conflict, timeout, partial failure, and handoff.

### Response subject

- See the exact request, claims, evidence scope, deadline, and privacy choices.
- Save a draft, attach material, answer question by question, and grant granular
  publication consent.
- Receive a durable receipt and later see status, decision, correction, or appeal.

### Paying organization

The first paid beachhead is a Korean investigative newsroom or public-interest
research organization with 3–20 recurring procurement investigators. The primary
users are data reporters, researchers, and civic analysts. The economic buyer is
the investigation editor or research director who owns research throughput and
budget. Public-agency internal audit and general corporate compliance are deferred
segments because they require a distinct tenancy, procurement, and conflict model.

The paid job is to turn recurring procurement records, documents, and updates into
a reviewable, reproducible evidence packet without rebuilding collection,
extraction, comparison, collaboration, approval, and delivery by hand. The first
paid product is one `Evidence Workspace` organization plan, packaged as Review
Console in a single-organization deployment. It is not a fourth surface or a
multi-tenant SaaS claim. Public evidence, right of reply, correction, and
public-interest access remain free.

## 3. Ten-second screen contract

Within ten seconds, every screen must answer the applicable questions in this
order:

1. **Where am I and what object is this?** Human title, object identity, scope.
2. **What is its current state?** Status, freshness, owner, last material change.
3. **What matters now?** Answer-first summary and the highest-priority exception.
4. **What is not known or disputed?** Missing data, counter-evidence, response.
5. **Why should I believe it?** Evidence count, source, exact locator, method,
   investigation path, and reproducible provenance.
6. **What happens next?** One primary action, owner, deadline, and consequence.

Internal operation IDs, schema field names, opaque UUIDs, and JSON are never the
primary user language. They may appear only in an explicitly opened technical
details view when useful for support or audit.

Each task page has at most one visually dominant primary action. A read-only,
policy, receipt, completed, blocked, or system page may declare
`PRIMARY_ACTION: NONE`; implementation never invents a state-changing action to
satisfy layout. Secondary actions are grouped by intent. Destructive or external
actions are never styled or worded as routine. Labels use verb-plus-object wording
and state the consequence; standalone labels such as “확인”, “처리”, and “계속” are
forbidden.

## 4. One decision spine

All product paths use the same typed, traceable spine:

```text
SourceAsset revision/hash/rights
-> EvidenceSegment + exact locator
-> Normalized procurement fact + transformation lineage
-> Immutable DatasetSnapshot + membership/watermark
-> Deterministic Signal
-> Case brief
-> AgentRun + validated typed Proposal
-> ApprovalRequest bound to exact digest
-> Authorized execution
-> Delivery/publication/state-change Receipt
```

No layer invents missing values to make a later schema look complete. Missing,
unknown, not configured, stale, and failed are first-class states.

### 4.1 Core journey closure

Authority journeys J-01 through J-12 are the minimum complete product. A screen or
command success is not a journey outcome. Each instance stores current accountable
owner, next owner, due/SLO, handoff state, and escalation. A handoff completes only
when the receiver acknowledges it; missing ownership is BLOCKED, not empty success.
The executable graph is exactly twelve journeys and 129 explicitly identified
edges: the existing J-01..J-09 set has 47 edges, J-10 has 17, J-11 has 29, and
J-12 has 36. Edge IDs, branch and convergence nodes, resolver authority, concrete
handler, handoff binding and acceptance case are one set-equal registry; positional
enumeration, inferred linear steps, fallback handlers and prose-only edges are
forbidden.

| Journey | Route anchors | Complete only when | Accountable owner |
| --- | --- | --- | --- |
| J-01 Public understanding | PUB-002, PUB-004, PUB-005, PUB-006 | Representative reader identifies current revision, anomaly-not-wrongdoing, one material unknown, and exact locator | Product/PdM for task; Editorial for truth |
| J-02 Reporter reproduction | PUB-004, PUB-005, PUB-006, PUB-018 | Stable revision citation and bundle contain rule/input digest, cohort, checksum, rights, and correction context | Public data product owner |
| J-03 Right of reply | CAS-009, RSP-001..008, CAS-008 | Approved request is verifiably delivered; responder understands scope, drafts/attaches/consents, gets submission or extension receipt; same submission becomes owned intake | Editorial response duty |
| J-04 Public correction | PUB-027, PUB-028, COR-001, COR-002 | Receipt, exact claim/revision triage, reasoned terminal decision, resulting revision/tombstone and notification link to request | Editorial correction duty |
| J-05 Signal triage | SIG-001, SIG-002, CAS-002, INT-002 | Exactly one DISMISS/NEEDS_DATA/MARK_DUPLICATE/PROMOTE_TO_CASE/LINK_TO_CASE branch is stored; a case or task branch completes only when its receiver accepts ownership | Triage lead, then named case/task owner |
| J-06 Investigation | CAS-002..014 | Owner, question, hypotheses, supporting/contrary evidence, unknowns, response, blockers and fixed review-ready snapshot exist | Lead investigator; Editorial accepts readiness |
| J-07 Independent review/publication | REV-001..003, CAS-013, CAS-014, PUB-004 | Only APPROVE reaches publisher handoff, authorization, executor, projection and public smoke. CHANGES_REQUIRED returns an owned task to J-06; REJECT is terminal; RECUSE creates a replacement generation | Review lead, then a distinct publisher |
| J-08 Correction/retraction | COR-001, COR-002, PUB-018, PUB-019 | New immutable correction or visible tombstone, rationale, independent decision, affected surfaces/feed, subscriber notice and root-cause task exist | Editorial correction duty; Legal when required |
| J-09 Source schema drift | SRC-005, SRC-006, OPS-001 | Payload quarantined, impact known, mapping/parser version approved and shadow-verified, replay receipted, health/freshness restored or visibly degraded | Data operations owner |
| J-10 AI research to evidence | CAS-010, CAS-011, CAS-005, CAS-004, OPS-003 | The run is settled, typed analysis and citations validate, a human atomically promotes the exact artifact to Evidence, and the same evidence ID/version/digest appears in CAS-005 and CAS-004 | Lead investigator; evidence-curator backup |
| J-11 Approved action to durable effect | Origin screen, INT-002, REV-002, REV-003 when applicable, OPS-003, AUD-001 | An exact proposal receives independent review, authorization precedes execution, a definitive durable receipt exists, and the origin context displays that receipt | Proposal owner, reviewer, executor or reconciliation owner |
| J-12 Paid value and retention | OPS-004, INT-002, OPS-001, OPS-005, SRC-002, SRC-005, SRC-006, CAS-002, CAS-004, CAS-005, CAS-010, CAS-011, CAS-013, REV-002, AUD-001 | A qualified organization reaches DATA_READY, produces one strict paid outcome, and produces two additional distinct paid roots in the fixed day-29-through-day-56 window | Product/PdM with Sales/CS/Finance and Data/SRE backups |

Required connected handoffs are `J-06 <-> J-10`,
`J-06 -> J-03 -> J-06 -> J-07 -> J-11(PUBLICATION) -> J-01`,
`J-01 -> J-04 -> J-08 -> J-01`, and
`J-12 -> optional J-10 -> mandatory J-11 -> J-12`. J-09 feeds every affected
queue and DATA_READY/freshness projection. A cross-journey transition preserves
the same root object, version/digest, owner binding, due/SLO and last receipt;
browser navigation alone is never a handoff. Cancellation, expiry, rejection,
unavailable access and dependency failure are explicit terminal or recoverable
outcomes with reason and receipt.

### 4.2 Normative journey additions

J-10 has the exact edge IDs below. `EVIDENCE_PROMOTED` is its sole success.
`ABSTAINED`, `FAILED`, `CANCELLED`, `BUDGET_BLOCKED`, `POLICY_BLOCKED` and
`NO_ELIGIBLE_ARTIFACT` are typed non-value terminals. `CANCEL_REQUESTED` and
`RECONCILIATION_REQUIRED` are nonterminal.

```text
J-10-E01 START_RUN
J-10-E02 OPEN_RUN
J-10-E03 TERMINAL_OBSERVED
J-10-E04 CANCEL_REQUESTED_BY_HUMAN
J-10-E05 PRE_DISPATCH_CANCELLED
J-10-E06 POST_DISPATCH_CANCEL_PENDING
J-10-E07 OUTCOME_AMBIGUOUS
J-10-E08 SAFE_RETRY_AUTHORIZED
J-10-E09 RECONCILIATION_TERMINAL
J-10-E10 RECONCILIATION_NO_CHANGE
J-10-E11 ANALYSIS_VERIFIED
J-10-E12 PROMOTION_CANDIDATE_SELECTED
J-10-E13 ARTIFACT_PROMOTED
J-10-E14 OPEN_PROMOTED_EVIDENCE
J-10-E15 PROMOTION_BINDING_VERIFIED
J-10-E16 OPEN_EVIDENCE_MATRIX
J-10-E17 PROMOTED_EVIDENCE_VISIBLE
```

J-11 has the exact edges below. `SUCCEEDED` is its sole durable success.
`PARTIALLY_SUCCEEDED` is a known-mixed terminal and is neither success nor paid
value. `RECONCILIATION_REQUIRED` is nonterminal.

```text
J-11-E01 CREATE_DRAFT
J-11-E02 UPDATE_DRAFT
J-11-E03 BIND_PREVIEW
J-11-E04 SUBMIT_FOR_REVIEW
J-11-E05 PROJECT_ASSIGNMENT
J-11-E06 CLAIM_REVIEW
J-11-E07 VERIFY_EXACT_SUBJECT
J-11-E08A APPROVE_QUORUM_INCOMPLETE
J-11-E08B APPROVE_POLICY_BLOCKED
J-11-E08C APPROVE_FINAL_QUEUED
J-11-E08D REJECT
J-11-E08E CHANGES_REQUIRED
J-11-E08F RECUSE
J-11-E09 CLAIM_EXECUTION
J-11-E10 BEGIN_DISPATCH
J-11-E11 RECORD_OBSERVATION
J-11-E12A CANCEL_PRE_DISPATCH
J-11-E12B CANCEL_POST_DISPATCH
J-11-E13 SAFE_RETRY
J-11-E14 RECONCILE_ACTION
J-11-E15 RETURN_DURABLE_RECEIPT_TO_ORIGIN
J-11-E16 WITHDRAW_PROPOSAL
J-11-E17 WITHDRAW_APPROVAL
J-11-E18 EXPIRE_OR_SUPERSEDE
J-11-E19 DISPATCH_COMMUNICATION_INTENT
J-11-E20 CLAIM_OUTBOUND_DELIVERY
J-11-E21 RECORD_PROVIDER_OBSERVATION
J-11-E22 RECONCILE_DELIVERY
J-11-E23 RETURN_DELIVERY_RECEIPT_TO_ORIGIN
```

J-12 uses the closed edge families below. The two and only two paid pairs are
`AUDITED_DELIVERY + OUTBOUND_DELIVERY(applied DELIVERED|READ)` and
`COMPLETED_DECISION_CYCLE + ORGANIZATION_DECISION(definitive SUCCEEDED)`.
AI output, suggestion acceptance, proposal approval, provider acceptance, invoice
and page view are never paid value.

```text
J-12-E01..E08        qualification/configuration/data-readiness ownership
J-12-E09A            optional AI path into J-10
J-12-E09B            human-only evidence path
J-12-E10..E13        validated analysis/evidence/immutable packet source
J-12-E14..E17        ActionProposal draft/preview/review claim
J-12-E18A..E18D      approve/change/recuse/reject-or-expire
J-12-E19A            ORGANIZATION_DECISION terminal branch
J-12-E19B            OUTBOUND_DELIVERY terminal branch
J-12-E19C            RECONCILIATION_REQUIRED
J-12-E20             authenticated reconciliation router
J-12-E21             PaidEvidencePacket finalization and outcome fact
J-12-E22             FIRST_PAID_VALUE -> ACTIVATED projection
J-12-E23..E26        retention watches, repeat workflows, RETAINED
J-12-E27             AT_RISK overlay
J-12-E28             evidence-grounded risk recovery
J-12-E29             contract-proof CHURNED
J-12-E30             immutable audit drill-down
```

### 4.3 Closed handoff spine

The handoff kinds are exactly `HS-01 RESPONSE_REQUEST_DELIVERY`,
`HS-02 RESPONSE_INTAKE_OWNERSHIP`, `HS-03 CASE_OWNERSHIP`,
`HS-04 SIGNAL_ENRICHMENT_TASK`, `HS-05 EDITORIAL_REVIEW_ASSIGNMENT`,
`HS-06 REVIEW_CHANGES_TASK`, `HS-07 PUBLICATION_ASSIGNMENT`,
`HS-08 ACTION_REVIEW_ASSIGNMENT`, `HS-09 ACTION_EXECUTION_CLAIM`,
`HS-10 ACTION_RECONCILIATION`, `HS-11 AI_RUN_RECONCILIATION`,
`HS-12 EVIDENCE_PROJECTION_ACK`, `HS-13 CORRECTION_OWNER`,
`HS-14 SOURCE_DRIFT_RECOVERY`, `HS-15 COMMERCIAL_REMEDIATION_TASK` and
`HS-16 RETENTION_WATCH_TASK`, `HS-17 COMMUNICATION_DELIVERY_OWNERSHIP`,
`HS-18 COMMUNICATION_DELIVERY_RECONCILIATION`,
`HS-19 PAID_PACKET_TERMINAL_BINDING` and
`HS-20 COMMERCIAL_CONTROL_EXTERNAL_ACK`.

`JourneyInstance`, `JourneyHandoff` and `JourneyTransitionReceipt` are closed
typed records. They bind the journey/edge, root and current object identity,
current/next owner, due/SLO, generation, version, binding digest, state,
escalation, prior receipt chain, audit and outbox identities. Instance states are
`ACTIVE|WAITING_ACK|BLOCKED|RECONCILIATION_REQUIRED|COMPLETED|CANCELLED|EXPIRED|REJECTED`;
handoff states are
`PENDING_ACK|ACKNOWLEDGED|DECLINED|EXPIRED|CANCELLED|SUPERSEDED`; stored
escalation is `NOT_DUE|DUE|ESCALATED|RESOLVED`. `NONE` is only the creation
sentinel for a new escalation identity and is never persisted.

A dynamic workflow DSL, arbitrary node or edge strings, and caller-selected
receiver are forbidden. An instance has at most one open handoff. `currentOwner`
changes only in the receiver's ACK transaction. A producer creates the handoff and
receipt in the owning domain transaction. A terminal instance cannot create a new
handoff. Reassignment terminalizes the prior generation before generation+1.
Persistence authority is `ops.journey_instances`, `ops.journey_handoffs` and
`ops.journey_transition_receipts`; numeric relation totals are always derived.

Every logical journey step advances the parent version and immutable receipt
sequence exactly once. The four authorized compound branches—decline with
replacement, expiry with replacement, compiled supersession, and terminal
outcome cancellation—therefore use two ordered parent updates and two receipts
inside one SERIALIZABLE transaction. Their first step clears the old active
handoff and next owner, preserves the current owner, resolves the old escalation
generation, and leaves the parent `ACTIVE`; its due time is the exact compiled
replacement-origin checkpoint, or the compiled destination/terminal-policy SLA
for outcome cancellation. The second step either creates generation+1 and ends
`WAITING_ACK/NOT_DUE`, or records the final outcome. Receipt `priorDueAt` and
`resultingDueAt` make every intermediate due-time change reconstructible.
`WAITING_ACK`, `BLOCKED`, or a terminal state is forbidden as the compound
step-one parent because it would respectively require an active pending handoff,
contradict the immediate replacement, or prohibit the second update.

All command and scheduler success receipts return a complete immutable
transition plus the exact final `JourneyInstance` head. A decision response
contains `decisionReceipt`, nullable `replacement`, and `finalParent`; scheduler
results use the same twelve-field final-parent composite for applied results and
an all-null group for zero-write dispositions. No adapter may reconstruct the
final head from request data or a later mutable read.

### 4.4 Operation reconciliation

The J-10 external commands are `cancelAgentRun` and
`promoteResearchArtifactToEvidence`; `reconcileAgentRun` is a service-assertion-only
private control command and has no browser action. J-11 adds
`withdrawActionProposal` and `withdrawActionDecision`. The handoff spine adds one
external command, `decideJourneyHandoff`, at
`POST /v1/internal/journey-handoffs/{handoffId}:decide`. Its request contains only
the path `handoffId`, expected version, expected binding digest,
`ACKNOWLEDGE|DECLINE`, and a reason for decline. The caller cannot submit journey,
edge, handoff kind, receiver or destination. The server reads the persisted
binding and compiled closed registry and changes a domain object only through the
registered atomic adapter.

Authentication-attempt identity and business idempotency identity are separate.
Every retry presents a fresh request-bound actor or service assertion JTI. After
signature, audience, request binding and semantic request validation succeed, the
service consumes that JTI in `ops.assertion_replay_guard` and appends one immutable
authorization-attempt audit before entering the business transaction. The stable
business request hash contains only the operation, immutable subject identity,
expected version/binding, decision, closed reason code and canonical reason digest.
Transport request ID, actor/service assertion JTI, assertion token bytes,
randomized ciphertext and plaintext reason are excluded. A finalized replay is
looked up only after the fresh assertion attempt is accepted and returns the
original stored response bytes; “zero-write replay” means zero second business,
domain, receipt, command-audit or outbox write, not omission of the new replay-guard
and authorization-attempt audit rows. Only a `NEW` business claim may encrypt a
reason or mutate a domain row. The business claim, effect and response finalization
commit in one SERIALIZABLE transaction, so a crash after assertion consumption but
before that transaction leaves only the attempt evidence and a retry with another
fresh JTI can safely claim; a crash inside the transaction leaves neither a claim
nor a partial effect. Reusing a JTI fails before the business claim, while changing
any stable business byte under one Idempotency-Key is `IDEMPOTENCY_CONFLICT`.

## 5. Information architecture and screen view-models

### 5.1 Surface and capability closure

The only surfaces are Public Web, Review Console, and Response Portal, and the 94
authority routes remain fixed. The Evidence Workspace is Review Console for one
configured organization per deployment; cross-organization switching,
self-service billing routes, tenant selectors, and public entitlement UI are out
of scope until a separate owner amendment.

Every addendum capability is assigned to existing screens in
`specs/product/owner-addendum-2026-07-14.yaml`. It may add only the exact operations
listed there. A capability that has no compatible screen, section, role, operation,
and receipt is `DESIGN_BLOCKED`; it may not be hidden behind a generic form or an
adapter-only claim.

### 5.2 Normative 94-screen closure

`implementation-evidence/design-screen-closure.yaml` contains exactly one row for
every authority screen ID and is normative. Each row fixes persona, job, object,
the six ten-second answers and their source mappings, existing section ownership,
typed view-model, exact state profile, primary action or `NONE`, consequences,
responsive order, keyboard/focus behavior, analytics allowlist, and operations.
Blank, inherited, generic, renderer-derived, or `TBD` values are invalid.

The matrix refines content inside an authority section but does not silently
remove, rename, or reorder `screen-build-manifest.yaml` sections. An incompatible
region is a recorded design conflict. No screen implementation begins until its
closure row is decision-complete and independently reviewed.

A populated row is not semantic closure. For each screen, a reviewer must be able
to follow one concrete, realistic object through all of the following without a
fallback template or keyword-derived copy:

1. the journey entry, predecessor and safe return path;
2. exact object identity, state, freshness, owner and highest-priority fact;
3. one material uncertainty, blocker or counter-evidence item when applicable;
4. evidence label, immutable source/locator and authorization-safe deep link;
5. primary action or explicit `NONE`, its consequence, required capability,
   operation, request binding, confirmation/assurance and durable receipt;
6. every state occurrence's trigger, visible copy, retained data, allowed action,
   recovery, focus target and next state;
7. section/component composition, compact/medium/wide order, keyboard order,
   screen-reader name and live/focus behavior; and
8. executable journey, state, accessibility, visual and analytics acceptance IDs.

Every declared command must be reachable from at least one authorized, context-
appropriate screen action unless the authority explicitly classifies it as
service-only. Every visible mutation must map back to exactly one declared command.
Generic operation runners, raw JSON editors, hidden admin links, invented selectors,
and route existence do not prove reachability. Sensitive tokens, cookies, provider
secrets and one-time proofs are never ten-second sources or view-model fields.

- Every one of the 94 routes owns a typed screen view-model. An API DTO is mapped
  into user concepts before rendering.
- A generic screen renderer, generic structured-content placeholder, whole-response
  dump, or raw JSON command form cannot satisfy a screen contract.
- Route parameters are explicitly bound to operation parameters, including aliases.
  A missing required binding is a contract error, never an empty success.
- The canonical browser routes are the token-free routes in `screen-catalog.yaml`:
  PUB-028 `/correction-request/receipt`, PUB-030 `/subscription/manage`, RSP-001
  `/respond/access`, and RSP-002..007 `/respond/{overview|answer|attachments|review|
  receipt|extension}`. A legacy token-bearing URL is an exchange endpoint, not a
  page: it validates once, establishes the authority-declared HttpOnly scoped
  session, removes the token with a same-origin `303`, sets `Referrer-Policy:
  no-referrer` and `Cache-Control: no-store`, and never logs, analyzes, embeds or
  redirects the token. Invalid/expired exchange goes to RSP-008 without revealing
  the request. The case-history redirect targets the existing `#revision` anchor.
- `agencySlug -> agencyId` and `supplierSlug -> supplierId` are explicit public
  aliases: the existing string path parameters accept the canonical public slug,
  resolve it through the identity alias relation, and return the UUID as the
  response identity. All other route/request aliases are exact-name bindings.
  `design-screen-closure.yaml` lists every route-to-request binding and every
  navigation action's destination, required source ID, preserved query keys and
  safe return context; implicit URL construction is invalid.
- List rows link to their own detail. Filters, sort, cursor, and result counts are
  real query inputs, survive navigation, and are reflected in the URL when safe.
- Related journeys preserve object and task context. The browser back action is
  safe and useful.

Every view-model implements the exact profile assigned by
`specs/ui/page-archetypes.yaml` plus screen-specific states. Names are normative:

- public-data: `initial-loading`, `refreshing`, `empty`, `filtered-empty`,
  `partial`, `stale`, `error`, `offline`, `success`;
- collection: `initial-loading`, `refreshing`, `empty`, `filtered-empty`,
  `partial`, `stale`, `invalid-filter`, `error`;
- static-content: `loading`, `current`, `superseded`, `error`;
- guided-submission: `loading`, `draft`, `saving`, `saved`, `validation-error`,
  `server-error`, `offline`, `session-expiring`, `success`;
- internal-data: `loading`, `refreshing`, `empty`, `partial`, `error`,
  `unauthorized`, `forbidden`, `conflict`, `degraded`;
- workspace: `loading`, `draft`, `saving`, `saved`, `blocked`, `conflict`,
  `unauthorized`, `forbidden`, `error`;
- decision: `loading`, `ready`, `blocked`, `stale`, `reauth-required`,
  `conflict`, `submitting`, `receipt`, `partial-failure`;
- operations: `loading`, `healthy`, `degraded`, `incident`, `telemetry-gap`,
  `error`, `forbidden`;
- system: `not-found`, `unauthenticated`, `forbidden`, `session-expired`,
  `maintenance`, `degraded`, `offline`, `error`.

A typed substate must preserve its normative parent and cannot collapse two states
into a generic status. Every error identifies affected scope, saved/draft state,
recovery action, support reference, and retry safety. Validation summaries receive
focus, link to exact fields, match inline errors, and preserve input.

The same information hierarchy remains recognizable in every state. Errors say
what happened, whether data was saved, what the user can do, and where to get help.
Conflict recovery preserves the user's draft and shows a comprehensible diff.

The response journey follows J-03/Flow 04: approved request delivery and
authenticity verification (RSP-001), overview (RSP-002), per-question draft
(RSP-003), upload and completed inspection (RSP-004), check answers and explicit
submit (RSP-005), durable receipt and internal intake (RSP-006 -> CAS-008).
Extension (RSP-007) and unavailable/expired/unrecoverable access (RSP-008) are
complete recovery branches, not dead ends. It uses labelled fields, autosave,
error summary, focus management, granular consent, and receipt. A responder never
authors an array or object as JSON.

J-03 has one durable submission authority. `submitResponse` persists the immutable
submission and emits only the token-free eight-field `response.submitted.v2`,
`notification.response_submitted.v2`, and `workflow.response_submitted.v2` set in
the same transaction; token-bearing v1 rows are historical and inactive. The
workflow v2 event is the sole owned-intake route. Its SERIALIZABLE materializer
claims the exact envelope, verifies the locked submission/request/case graph,
creates one `editorial.responses` row, writes reciprocal composite pointers, and
terminalizes a typed inbox result together with audit/outbox. Exact replay writes
nothing, a distinct byte-equal event records only the declared no-op, and any
one-sided or changed graph is `EVENT_EFFECT_CONFLICT`.

Every Response Portal operation calls one database-owned portal-window resolver.
The requested `due_at` is never expiry authority: `effective_due_at` is null until
verified delivery, otherwise it is the deadline, with only a timely still-pending
extension preserving access. OTP success is never a caller boolean. The stable
access artifact stores a versioned purpose-HMAC verifier; PostgreSQL compares the
candidate verifier while holding the artifact/session and only an exact winner may
rotate pending to active. Delivery observation likewise derives `observed_at` from
the transaction or locked callback/reconciliation receipt. Stale observations
produce audit but no outbox/event version. A retry ordinal greater than one must
composite-reference the latest immutable `RETRY_SCHEDULED` reconciliation decision
whose typed proof the database reconstructs under the same delivery/provider key
and request digest.

## 6. Cognitive load, responsive behavior, and accessibility

Gurinnae conforms to WCAG 2.2 Level AA. Use plain Korean first and expand domain
terms at first use. Lead with the answer, then adjacent uncertainty, evidence,
method, and technical detail. Dates include timezone; quantities include unit and
comparison basis; status never relies on color, icon, or motion alone.

The visual authority is, in order, `specs/ui/FINAL_DESIGN_SYSTEM.md`,
`design-tokens.yaml`, `screen-build-manifest.yaml`, `component-catalog.yaml`, and
`FINAL_COMPONENT_MANUAL.md`. All 58 component contracts remain mandatory.
Addendum variants do not create one-off visual grammar or raw primitive colors.

- Layout decisions use container width: compact 20rem–39.99rem, medium
  40rem–63.99rem, wide 64rem–89.99rem, extra-wide 90rem and above.
- Required checks run at 320x568, 768x1024, and 1440x900 CSS pixels and at 200%
  and 400% zoom from 1280x1024. There is no page-level two-dimensional scrolling,
  clipped text, obscured focus, lost information, or unavailable core function.
- Compact preserves state, blocker, core answer, evidence, impact, and next action
  in that order. Medium/wide may add columns but never change semantic, keyboard,
  heading, or screen-reader order. Review Console may give explicit
  desktop-required guidance only for authority-declared complex editing; read,
  approval, incident, reauthentication, and receipt remain fully usable.
- Tables retain labels, units, headers, and row actions when converted. An
  inherently two-dimensional source may use a labelled scrolling region only with
  an accessible equivalent.
- Every function is keyboard operable with visible focus, working skip links, no
  trap, Escape behavior, dialog containment/restoration, and a non-drag path.
  Drawers restore focus and sticky actions never cover content, errors, or the
  virtual keyboard.
- Names, roles, values, busy state, validation messages, and asynchronous outcomes
  are semantic. Live announcements occur once and never steal focus.
- Interactive targets are at least 44 by 44 CSS pixels except adequately separated
  inline text links. WCAG text and non-text contrast apply.
- `prefers-reduced-motion: reduce` removes non-essential animation, parallax,
  autoplay, smooth scrolling, and motion transitions without hiding state.
- Manual critical journeys run with pinned NVDA+Firefox and VoiceOver+Safari in
  addition to automated component, axe, visual, zoom, and reflow checks.

### 6.1 Representative usability gate

Critical tasks are: public case comprehension and locator; search match and
evidence; investigation blocker/counter-evidence/next action; exact approval;
response draft/consent/submission/receipt; and return-visit change recognition.
The designated screens are PUB-004, PUB-006, RSP-002 through RSP-006, SIG-002,
CAS-002, CAS-004, CAS-011, REV-002, REV-003, OPS-006, and AUTH-004.

Each applicable cohort—public evidence user, investigator/operator,
reviewer/approver, and response subject—has at least ten qualified participants,
including at least two keyboard-only and at least two screen-reader or 200%/400%
zoom users; categories may overlap. Tests use realistic non-empty data, fresh
starting context, no coaching, and assigned compact/wide/assistive conditions.

A cohort/task passes only when at least 9/10 correctly state the object, current
state, one material fact, highest-priority unknown/blocker, evidence entry, next
action, and consequence within ten seconds; at least 9/10 reach the evidence or
uncertainty within 45 seconds; at least 9/10 finish without assistance or critical
error; median Single Ease Question is at least 6/7; and nobody approves the wrong
content/recipient, mistakes uncertainty for fact, loses input, or grants unintended
consent. The receipt records cohort, task/route, data revision, viewport, zoom,
browser/AT, timings, outcome, assistance, errors, SEQ, and redacted observation
hash. Automated checks do not substitute for this evidence.

## 7. Search and evidence visualization

Search is a retrieval product, not a text box.

- Public integrated search supports exactly `CASE`, `CONTRACT`, `AGENCY`,
  `SUPPLIER`, `METHODOLOGY`, and `CORRECTION`. INT-003 supports exactly `CASE`,
  `SIGNAL`, `EVIDENCE`, `AGENT_RUN`, and `AUDIT_EVENT`; AUD-001 retains dedicated
  audit search. Collection screens filter only their declared operation types.
  Unified search never silently adds SOURCE, DATASET, RULE, TASK, or another type.
  Permission/classification filtering occurs before candidates, rank, counts,
  snippets, suggestions and pagination; no inaccessible title/timing/count leaks.
- Existing search paths remain. `searchPublicRecords` exposes only `q`, `types`,
  `publicationState`, `dateFrom`, `dateTo`, `cursor`, `limit`, and `sort`;
  `searchInternalRecords` exposes only `q`, `types`, `status`, `cursor`, `limit`,
  and `sort`; audit search exposes only its declared actor/action/object/outcome/
  time inputs. Public `types` and `publicationState`, internal `types` and the
  type-qualified `status` union, defaults, combinations, and empty-array behavior
  are the closed values in `owner-addendum-2026-07-14.yaml`. The UI provides only
  controls for those declared filters. It does not expose facet counts, a source
  filter, or an undeclared filter. Query/filter/sort/limit change clears cursor.
- Additive result schemas expose `SearchMatchV1`, object revision/freshness, and
  page projection generation/watermark/ranking-policy version. `SearchMatchV1`
  reason is `EXACT_IDENTIFIER | EXACT_CANONICAL_TITLE | EXACT_QUOTED_PHRASE |
  VERIFIED_ALIAS | CANONICAL_PREFIX | FULL_TEXT | TRIGRAM_FALLBACK`; field is
  `IDENTIFIER | TITLE | CANONICAL_NAME | VERIFIED_ALIAS | SUMMARY | BODY |
  LOCATOR`; text is authorized plain text; ranges are sorted non-overlapping
  half-open UTF-16 offsets. Renderer splits plain text, never HTML. A hit without a
  safe non-empty explanation is contract failure. `totalApproximate` is labelled
  approximate; absence is unavailable, not zero. Page as-of is index freshness,
  item freshness/updated-at is object state.
- Each operation's declared type/date/publication-state/status controls,
  deterministic ordering, keyset pagination, and empty/no-access/error states are
  implemented end to end. There is no generic facet/source-filter requirement.
- Query grammar accepts balanced double-quoted phrases and conjunctive unquoted
  terms. Boolean, wildcard, and embedded field syntax are unsupported; unbalanced
  quote/operator yields INVALID_PARAMETER/invalid-filter, never broadening.
  Normalization retains display query, applies Unicode NFKC, meaningful case fold,
  collapses whitespace, tokenizes Korean as Hangul-syllable/number/Latin sequences,
  preserves phrase order/punctuation, and retains separator-insensitive identifier
  key. It never claims English stemming segments Korean.
- A fixed reference-query set must achieve `Recall@10 >= 0.95`; representative
  indexed search must meet the authority latency SLO.
- Locator union preserves base `PAGE_BBOX`, `XLSX_CELL`, `CSV_ROW_COLUMN`,
  `XML_XPATH`, `DOCX_PARAGRAPH`, and `HWPX_XPATH`, and adds only `JSON_POINTER`,
  `HTML_CSS_SELECTOR`, `API_FIELD`, and `TEXT_RANGE`. PDF page/region and
  spreadsheet cell are presentation labels, not persisted replacement kinds.
  Every locator binds canonical value, asset ID/revision/content SHA-256,
  retrieval time, source authority, extraction version, selected-content SHA-256,
  optional transformation version, and canonical locator digest. Derived text
  never replaces raw asset/digest.

### 7.1 Index, rank, cursor, and projection contract

`public.search_documents` and `ops.search_documents` are dedicated typed
projections. Production projector events and deterministic backfill populate them;
fixture writes are not a production path. Each row binds object revision,
surface, visibility/classification, required capabilities, canonical/verified-alias/
identifier fields, authorized searchable content, href, status, source freshness,
updated time, source event/version, generation and watermark. Rebuild verifies a
canonical digest then atomically activates a new generation; prior generation lasts
only cursor retention. A public alias ranks only with source document and VERIFIED
entity identity.

Ranking tiers are deterministic:

1. exact identifier;
2. exact normalized canonical title;
3. exact quoted phrase;
4. exact verified alias;
5. canonical-title or verified-alias prefix;
6. PostgreSQL 18.4 `ts_rank_cd` over conjunctive indexed terms;
7. `pg_trgm` fallback only for unquoted normalized queries of at least three
   characters, only if tiers 1–6 are empty, similarity at least 0.45.

Tiers 1–5 have the constant score `1.000000`; their order comes only from tier and
the common tie tuple. Tier 6 uses one persisted `search_vector` built with PostgreSQL
`simple` configuration from projector-produced normalized token strings: weight A
is identifier plus canonical title/name, B is verified aliases, C is summary, and
D is authorized body plus locator. Its exact function is
`ts_rank_cd(ARRAY[0.05,0.20,0.50,1.00]::real[], search_vector,
plainto_tsquery('simple', conjunctive_terms), 32)`. Tier 7 score is
`similarity(normalized_query, normalized_title)`. Both statistical scores are
converted to `numeric` and rounded to six decimal places before comparison or
cursor encoding; no platform float is compared after quantization. A document
that matches multiple tiers keeps only its lowest tier and that tier's score.

Scores quantize to six decimals. Default keyset is `tier ASC, score DESC,
normalized_title ASC, object_type_order ASC, object_id ASC, object_revision ASC`.
Public type order is CASE, CONTRACT, AGENCY, SUPPLIER, METHODOLOGY, CORRECTION;
internal is CASE, SIGNAL, EVIDENCE, AGENT_RUN, AUDIT_EVENT. `updated_desc` is
updated-at descending nulls-last then title/type/ID/revision; `title_asc` is title/
type/ID/revision. Freshness is visible but not hidden relevance boost. Risk,
severity, allegation, click/share, customer, payment and funding never rank. Each
hit returns winning tier and match reason.

Cursor v1 is encrypted/authenticated and binds schema, surface, query/filter digest,
sort, limit, ranking policy, generation/watermark, complete sort tuple,
authorization-scope digest, issue time and expiry. Public scope is fixed; internal
scope covers actor capabilities, object scopes, classification policy/version.
Public expires 30 minutes, internal 10. Malformed/expired/cross-surface/scope or
query/filter/sort/limit/generation/policy mismatch is INVALID_CURSOR. Recovery
preserves safe query/filter/sort, clears cursor, focuses results, and explains
restart. Authorization/visibility re-evaluates each page; permission change
invalidates internal cursor, newly restricted hit is omitted and page becomes
partial. Immutable eligible generation yields no duplicate/unexplained omission.
Pagination uses next cursor and known browser history, never inferred numbered page
or invented previous cursor.

Every public page also performs one current-state overlay read after selecting the
pinned-generation candidates. An object that is no longer public is omitted and
sets `partialDueToVisibilityChange`; every remaining item carries the required
`PublicSearchStateOverlayV1`. A correction or retraction committed after the page
watermark supplies its current revision, `CORRECTED` or `RETRACTED` notice kind,
notice URL, and whether the matched conclusion is invalidated. `NONE` has a null
notice URL and cannot conceal a newer correction or retraction. The overlay never
changes pinned rank or cursor tuple, and `visibilityAsOf` records the authoritative
overlay read time. Thus cursor stability cannot make superseded content appear
current. Exact additive wire fields, types, requiredness, tier/reason mapping, and
filter values are normative in `owner-addendum-2026-07-14.yaml`.

### 7.2 Evidence deep links and provenance

A locator link carries public revision or internal snapshot ID, evidence segment
ID, locator type, locator digest, and safe return context. The destination verifies
the digest and focuses/highlights the exact paragraph, cell, API field, page/region,
or image region from the exact immutable asset. Missing, redacted, restricted,
superseded, source-loss, or digest mismatch shows that exact state. Another
authorized revision may be offered only as a separately labelled link with diff;
it is never automatically highlighted as requested evidence.

Additive `PublicEvidence.provenance` and `EvidenceDetail.provenance` supply the exact
source-document and asset identity/revision, source authority, retrieved-at,
canonical locator kind/value/digest, raw and selected-value SHA-256, parser and
optional transformation versions. Existing `contentSha256` remains the
revision-fixed source digest and must equal the provenance source-content digest.
Their exact types and requiredness are normative in the owner addendum. A material
public claim missing a trace field cannot pass publication. Provenance also has an
ordered-list equivalent, stable citation labels and copyable digest/locator.

The provenance graph uses closed node kinds `SOURCE_ASSET`, `PARSER_RUN`,
`EVIDENCE_SEGMENT`, `NORMALIZATION_RUN`, `NORMALIZED_FIELD`, `DATASET_SNAPSHOT`,
`RULE_RUN`, `SIGNAL`, `CLAIM`, `PUBLICATION_REVISION`, `AGENT_TOOL_CALL`,
`PROPOSAL`, and `RECEIPT`, with typed transformation/support/contradiction edges.
Every visible edge is backed by an FK or immutable join row. Redacted or
unauthorized nodes are explicit gaps; the UI never draws an inferred continuous
line. Public provenance stops at public-safe nodes, while internal views preserve
classification and purpose checks.

Chart and table consume one immutable `VisualizationVm`: named question, takeaway,
source/snapshot/watermark, canonical data digest, as-of/freshness, measure, unit,
VAT, timezone/period, rounding, denominator, cohort definition, included/excluded
rows/reasons, unknowns, series/points, uncertainty and source refs. They never
independently refetch/transform. Dot/distribution table has each plotted record;
histogram exact bucket/count/percent plus cohort; boxplot five numbers/N plus cohort;
trend each time/series point; comparison target and every included/excluded reason.
Table is keyboard reachable and visible to all, with identical digest/filter/cohort/
unit/rounding. Zero, filtered zero, gap, unknown, restricted and error are distinct.
Tooltip/color/shape/motion is never sole source. Unsupported data yields unknown or
table, not invented KPI.

Versioned reference corpus contains at least 120 synthetic queries covering every
type/tier, ID, phrase, verified alias, Korean normalization, correction/retraction,
filter/sort, locator, no-result and authorization-negative case, with actor scope,
projection digest, graded relevant/forbidden IDs, top hit and match reason. Release
requires exact-ID Recall@1 100%, macro Recall@10 at least 0.95, nDCG@10 at least
0.85, URL/filter round-trip 100%, no cursor duplicate/unexplained omission, zero
inaccessible hit/snippet/count/suggestion/cursor disclosure, and one keyboard step
from material fact to locator. Production projector builds at least one million
public and one million internal rows; 1,000 uncached searches at concurrency 20
meet public P95 400 ms and internal P95 600 ms with recorded corpus/index/hardware/
PostgreSQL/cache/workload/histogram evidence. Chart/table digest equality is 100%.

## 8. AI and multimodal analysis

AI may search, compare, summarize, challenge, cite, and draft. It may not publish,
send, merge identities, decide guilt, or mutate authoritative case state.

The product pipeline is one closed evidence loop, not a chat response or a generic
blob store:

```text
authorized source or Internet fetch + multimodal bytes
-> immutable raw asset/ResearchArtifact + rights/classification
-> format-specific parser/OCR/transcription/caption + exact locator
-> normalized typed facts + field provenance
-> immutable DatasetSnapshot in PostgreSQL/object storage/search projections
-> typed AgentRun/ProviderTurn/ToolCall/SourceUse
-> validated analysis + citations + supporting/contrary evidence
-> one digest-bound VisualizationVm and accessible table
-> typed AgentProposal
-> human accept/reject/change/recuse decision
-> separate execution authorization
-> channel or domain effect + receipt/reconciliation
```

CAS-010/CAS-011 and connected case screens must make four questions immediately
answerable: what was found, what may be suspicious and why it is not yet a fact,
how the system investigated it with which sources/tools, and what a named person
should do next. The view-model is a closed typed union for runs, turns, tools,
findings, citations, provenance nodes/edges, visualizations, unknowns, policy
blocks, proposals and receipts. A string summary plus UUID citations, generic
tool schema, or `Record<string, unknown>` is not this product.

- All five agents execute their declared read-only tools through real adapters.
- Provider requests include authorized source content or derived segments, not
  identifiers pretending to be evidence.
- HTML, document, table, image, and scan inputs retain source hash, rights, locator,
  extraction version, and confidence.
- Each agent uses a versioned prompt and its exact output JSON Schema. Generic
  validators are forbidden.
- Every citation is checked against the immutable input snapshot and opens the
  exact source locator. Invalid citation produces an explicit abstention and no
  partial application.
- Store tool requests/results, prompt and schema versions, snapshot digest,
  validation result, latency, and cost. Do not store or present hidden chain of
  thought. Show concise rationale derived from sources, tool use, and policy.
- Detection runs read immutable dataset snapshots, never ad hoc evaluation payloads
  hidden in rule configuration.
- Accepting any agent suggestion materializes exactly one typed `ActionProposal`
  `DRAFT` through a validated human command and zero authoritative domain target or
  external effect; only the later approval executor may create the typed effect.

### 8.1 Tool-turn protocol and Internet boundary

`analysis-worker` owns `AgentToolDispatcher`. Each provider turn is exactly one
closed envelope: `FINAL_OUTPUT` or `TOOL_CALL { callId, toolId, arguments }`.
Before executing one call, the dispatcher validates agent/tool allowlist, exact
request schema, run/snapshot scope, iteration, timeout, rights, classification,
and budget reservation. `(runId, callId)` is idempotent; replay returns the stored
result. Request/result digests, redacted payload, latency, cost, status, and prior
transcript digest are append-only. Exhausted iterations or budget produce an
explicit abstention and no further call.

Eight internal tools are snapshot-scoped read-only PostgreSQL adapters.
`source.fetch` uses closed `SEARCH_PUBLIC_WEB | FETCH_URL` requests and only the
`analysis-worker -> egress-gateway` research channel. It enforces HTTPS, approved
source policy, redirect-by-redirect DNS/IP/private-range validation, byte/time/
redirect limits, and static HTML; JavaScript-required pages stop as
`RENDER_REQUIRED`. Raw bytes and headers become hash-pinned `ResearchArtifact`s,
not authoritative evidence. A separate human command promotes a selected artifact
into SourceDocument/Evidence before it can support a claim, publication, or
external action.

`SEARCH_PUBLIC_WEB` has one concrete production adapter,
`BRAVE_SEARCH_WEB_V1`, pinned to `GET https://api.search.brave.com/res/v1/web/search`.
It starts `UNCONFIGURED`; activation requires the gateway-only
`BRAVE_SEARCH_API_KEY`, reviewed provider/jurisdiction terms, exact configuration,
source-policy, quota, micro-KRW price/FX and live preflight receipts. Search snippets
are untrusted discovery metadata and never evidence or model input. The gateway
binds the exact request, provider/configuration, response body, result ordinals,
price calculation and replay identity in a typed discovery receipt. Exact replay
issues no second provider request; possible-send ambiguity never falls back or
double-settles cost. Each selected URL must pass a separate `FETCH_URL`, raw-byte
storage and scan before it can become a `ResearchArtifact`. An unofficial scraper,
model-native search, browser search or canned result is never a fallback.

### 8.2 Dataset snapshots and lineage

`DatasetSnapshot` is created in a PostgreSQL `REPEATABLE READ` transaction. Each
immutable member stores object type/ID/version, canonical payload, payload SHA-256,
source-document IDs, and normalization version; a mutable pointer alone is invalid.
Members sort by `(objectType, objectId, objectVersion)`. Snapshot digest is canonical
JSON SHA-256 over schema version, source watermarks, normalization versions, and
ordered member digests.

A RuleRun requires a `READY` snapshot FK, exact RuleVersion, code digest, and
configuration digest. Inline production `evaluationInput` is rejected. Input
digest binds rule/version/configuration/snapshot; changing core rows after snapshot
creation cannot change a rerun's byte-equivalent result.

Lineage is explicit FK or immutable join rows through:

```text
SourceDocument -> ParserRun -> EvidenceSegment/ParsedRecord
-> NormalizationRun/FieldProvenance -> DatasetSnapshotMember
-> RuleRun/Signal -> CaseEvidence -> AgentToolCall
-> AgentProposal -> HumanCommand -> Receipt
```

Opaque JSON ID arrays never substitute for these links.

### 8.3 Agent proposals and citation authority

Each proposed item is a separate `AgentProposal` with `runId`, `caseId`,
`proposalType`, target schema version, typed payload, payload SHA-256, input
snapshot digest, citation-validation ID, state, version, and expiry. Allowed states
are `PENDING -> ACCEPTED | REJECTED | SUPERSEDED | EXPIRED`.

Acceptance requires proposal ID, expected version, expected payload digest, reason,
and Idempotency-Key. In one transaction it locks the proposal, rechecks snapshot,
citations and case version, and creates exactly one `ActionProposal` in `DRAFT`
with `origin_kind=AGENT_SUGGESTION`, the matching typed action-detail branch and a
backward proposal/version/payload binding. This single boundary applies to
`HYPOTHESIS`, `CLAIM`, `TASK`, `COMPARABLE`, and `COMMUNICATION`; accepting an agent
proposal never creates an editorial hypothesis, claim, task, comparable fact,
communication intent, authorization, attempt, or external effect. Those effects may
be created only by the separately authorized `submitActionDecision` executor after
the normal preview, assignment, quorum, recusal, policy, budget and fencing gates.
A comparable remains an unverified proposal payload until that executor and later
evidence verification create an authoritative fact.

Agent citation v2 is `{sourceKind, sourceId, locator, contentSha256, supports}`.
`sourceKind` is `EVIDENCE_SEGMENT` or `RUN_TOOL_ARTIFACT`. Claims, publication, and
external-action rationale accept only verified EvidenceSegments; a tool artifact
is research/candidate context until promoted. The deterministic citation validator
is authoritative; the citation-verifier Agent is advisory.

Schema failure makes the run `FAILED/OUTPUT_SCHEMA_INVALID`. A snapshot-outside
ID or locator/hash mismatch changes the whole output to the exact authority
`ABSTAINED` reason and produces zero proposals. Partial application is forbidden.
Historical v1 output remains read-only; new production runs use v2.

J-10 is the sole research-to-authoritative-Evidence journey. A validated run or
accepted suggestion is not Evidence. Only `promoteResearchArtifactToEvidence`
may atomically create the source-document revision, Evidence segments, promotion,
audit, outbox and receipt after revalidating bytes, rights, parser, locators and
selected-content digests. `cancelAgentRun` distinguishes definitive pre-dispatch
cancellation from a possible effect; service-only `reconcileAgentRun` accepts only
run-bound authenticated evidence and no human override.

### 8.4 Multimodal matrix and model egress

The additive media are `text/html`, `image/png`, `image/jpeg`, `image/webp`,
`image/tiff`, WAV audio, and WebM video; all v13 formats remain. HTML
preserves raw bytes, executes no script or style, and emits DOM text/link segments
with CSS locators. Independent images use sandboxed OCR with word/line bounding
boxes, language, and confidence. Audio produces timestamped transcript segments,
confidence, acoustic-source locators, and a speaker label only when the parser has
evidence for it. Video preserves container/stream metadata and produces timestamped
visual shots, captions, transcript segments when audio is present, and region/time
locators. WebM without a usable declared audio stream still runs the visual path;
silence or absent audio is recorded, not fabricated. Unsupported codec, corrupt
bytes, truncation, resource limit and low-confidence output are typed non-success
states with zero promoted evidence. Format sniffing uses verified bytes rather
than filename, and every parser has real golden fixtures plus malformed and
adversarial cases.

VLM caption/table/visual observations require `model_use` rights and provider/
classification activation, and remain proposals rather than verified facts.
Only PUBLIC and provider-approved INTERNAL segments may leave for an external
model. RESTRICTED, legal-hold, or unknown model-use rights are local-only or
`POLICY_BLOCKED`. Every derivative retains asset digest, region locator,
extraction/model version, and confidence.

## 9. Human approval and external action

AI proposes; a human decides; a separately authorized executor acts.

An approval screen must show, using the exact ActionKind branch rather than a
generic JSON fact bag:

- why the action is proposed and what evidence supports it;
- exact action type and expected state transition;
- recipient, channel, destination identity, locale, consent, suppression,
  rendering and terminal-delivery meaning when and only when the action is a
  communication;
- exact public/rendered bytes and attachments when the selected action has an
  external byte effect;
- risk, cost, expiry, reversibility, and likely effect;
- conflicts, recusal requirements, required assurance, and approval quorum.

Approval is bound to the exact draft, target, evidence, action-specific detail and
effect context. Communication recipient/channel/provider values are not flattened
into unrelated action kinds.
Stale digests, replay, self-approval, conflicted reviewers, insufficient assurance,
or missing quorum fail closed. `approve`, `reject`, and `request changes` are distinct
commands. A requested change can never be submitted as approval.

No discretionary provider side effect occurs before approval. Cancellation and
scoped kill switches fence queued and in-flight work. Execution returns a durable
receipt with idempotency key, attempt, provider acknowledgement, terminal status,
timestamps, and reconciliation state. The UI retains the receipt rather than
replacing it with a generic success notice.

### 9.1 API and canonical approval binding

The ActionProposal HTTP surface is exactly thirteen operations: three queries and
ten commands. The ten commands include `withdrawActionProposal` and
`withdrawActionDecision`; approval withdrawal is not a fifth
`submitActionDecision` variant. `releaseLegalHold` is a separate trust command.
`submitActionDecision` is a closed `oneOf` for `APPROVE`, `REJECT`,
`CHANGES_REQUIRED`, and `RECUSE`; label/body mismatch and absent discriminator are
rejected. `acceptAgentSuggestion` may create one typed draft but never authorizes
or executes an external effect.

`ApprovalBindingV1` uses Gurine Canonical JSON v1. It has one closed common
binding plus one closed action-specific detail union. The common field set is
exactly:

```text
schemaVersion, proposalId, proposalVersion, actionKind,
originDigest, contentDigest, rationaleDigest,
targetType, targetId, targetVersion, targetDigest, objectScopeDigest,
operationId, requiredCapability, targetRequestDigest,
previewId, approvalSubjectDigest,
evidenceSetDigest, contraryEvidenceSetDigest, uncertaintySetDigest,
riskAssessmentDigest, policySnapshotDigest, conflictSnapshotDigest,
expectedEffectDigest, reversible, quorumPlanDigest,
effectIdempotencyKeySha256, notBefore, expiresAt,
actionDetailKind, actionDetail, actionDetailDigest
```

`actionKind == actionDetailKind`. `actionDetail` is an
`additionalProperties=false` discriminated union with exactly seventeen branches:
`HYPOTHESIS`, `CLAIM`, `TASK`, `COMPARABLE`, `COMMUNICATION`, `PUBLICATION`,
`RETRACTION`, `RULE_ACTIVATION`, `ROLE_GRANT`, `KILL_SWITCH`,
`COMMUNICATION_AUTHORIZATION`, `ASSET_RIGHTS_DECISION`, `RETENTION_SCHEDULE`,
`FUNDING_DISCLOSURE`, `CAPABILITY_ACTIVATION`, `RESPONSE_POLICY_CALENDAR`, and
`COMMERCIAL_CONTROL`. `CORRECTION` stays in the correction/publication-gate
lifecycle and is not an ActionKind. A branch owns only its meaningful typed
fields. Inapplicable provider, recipient, consent, rendering, cost or governance
values must not be represented by nulls, empty digests, or sentinel values in
other branches.

```text
contentDigest       = SHA256(RFC8785_JCS(ActionPayloadV1))
targetRequestDigest = SHA256(GURINE_CANONICAL_JSON_V1({actionKind,targetRequest}))
actionDetailDigest  = SHA256(GURINE_CANONICAL_JSON_V1({actionDetailKind,actionDetail}))
approvalSubjectDigest = SHA256(GURINE_CANONICAL_JSON_V1(the exact readable
                                                       subject branch))
approvalDigest      = SHA256(GURINE_CANONICAL_JSON_V1(ApprovalBindingV1))
```

The database stores canonical bytes and digests and has exactly one typed 1:1
detail row for the selected branch. A deferred commit-time validator proves the
parent kind, detail kind, canonical detail bytes, typed child projection and every
source ID/version/digest candidate key are equal, while the other sixteen detail
tables have no row. There is no compatibility reader for the retired flat
24/43-field shapes because no production migration has persisted them.

`approvalDigest` is SHA-256 of canonical UTF-8 bytes. The contextual
`decisionDigest` alias is forbidden. `decisionKind` is deliberately
not inside this common digest: each `ActionDecisionV1` separately binds
`{approvalDigest, decisionKind, reason, actor, assignment, assurance, decidedAt}`.
This lets APPROVE, REJECT, CHANGES_REQUIRED and RECUSE address the same exact
subject without manufacturing different content digests. Only APPROVE decisions
for one identical proposal version and `approvalDigest` count toward quorum. For
approval, the ActionAuthorizationContext binds proposal ID as aggregate, proposal
version as expected version, and approval digest as business payload. Changing any
common binding field creates a new proposal version, supersedes the old one, and
invalidates every prior decision. Authoritative values are never copied from an
untrusted form.

The human Actor Assertion authorizes only the immutable decision transaction. That
transaction atomically inserts the decision and, when exact quorum is met, one
ExecutionAuthorization and outbox event. A worker acts with separate service
identity after revalidating the persisted authorization; it never reuses browser
assertions or raw step-up material.

### 9.2 Authorization, assurance, independence, and quorum

The compiled `specs/auth/assurance-policy.yaml` is the sole evaluator for existing
operations. A conditional branch resolving to STEP_UP is a STEP_UP action even if
the operation default is ACTIVE_SESSION. For `submitActionDecision`, external
delivery/publication/provider effects require STEP_UP; reject, changes-required,
and recuse require ACTIVE_SESSION. Control independently derives required assurance
from the discriminator and authoritative proposal and must match the signed
assertion. Client risk labels or screen metadata cannot lower it.

A STEP_UP retry preserves exact bytes and Idempotency-Key, uses a fresh Actor
Assertion JTI, the five-minute authorization, and at most three assertion issues.
A terminal decision receipt closes it. Confirmation styling is never assurance.

Quorum is evaluated against one immutable version/digest. A service, agent,
duplicate human, or recused assignment fills no human slot. The stricter of this
matrix and existing authority applies, and one human cannot occupy multiple slots:

- internal materialization without external effect: one authorized human;
- single-recipient discretionary communication: one independent
  `communications.approve` human, distinct from draft creator, last editor,
  recipient, and endpoint verifier;
- multi-recipient/broadcast: two humans—one `communications.approve`, one target
  domain capability;
- publication: current independent review quorum plus distinct publisher; required
  legal review is another distinct approval;
- retraction: editor plus publisher; high risk also distinct legal approval;
- rule activation: proposer cannot be sole production approver;
- role grant: subject cannot approve or execute the grant;
- broad kill switch: two distinct authorized humans.

Conflict evaluation covers exact authorship, editing, target ownership, recipient
relationship, role conflict, and declared personal, political, funding, or
commercial relationship. `RECUSE` records a mandatory reason, fills no slot,
terminates only that assignment, and returns work for reassignment. Publication and
external delivery have no conflict waiver.

### 9.3 Proposal, assignment, and decision state machines

```text
ActionProposal:
DRAFT -> PENDING_QUORUM -> APPROVED
DRAFT|PENDING_QUORUM -> CHANGES_REQUIRED|REJECTED|WITHDRAWN|EXPIRED|SUPERSEDED

ActionReviewAssignment:
VACANT -> ASSIGNED -> IN_PROGRESS -> COMPLETED
ASSIGNED|IN_PROGRESS -> RECUSED|CANCELLED
```

APPROVE appends one decision; only final quorum creates execution authorization.
The final quorum transition has one application owner and one transaction. A
single `atomicTransitionGroupId` binds the counted final decision, proposal state
change, exactly one ExecutionAuthorization, audit row and outbox event. A worker,
projector or second materializer may consume that event but cannot create another
authorization or independently reinterpret quorum.
REJECTED is terminal for that version. CHANGES_REQUIRED is terminal for that
version, invalidates approvals, and creates structured change tasks with owner,
due date, blocker, and verification method; completion creates a new version and
new review. RECUSE changes neither content nor proposal decision. Expired or
superseded versions never reopen. All decision variants require a non-empty reason.
`withdrawActionProposal` applies only to DRAFT or PENDING_QUORUM before any
ExecutionAuthorization. `withdrawActionDecision` appends one withdrawal for the
same human's current unwithdrawn APPROVE before final quorum; it never rewrites the
original decision and creates generation+1 as ASSIGNED or VACANT.

### 9.4 Execution fencing, cancellation, and receipts

ExecutionAttempt states are `QUEUED`, `CLAIMED`, `DISPATCHING`,
`PROVIDER_ACCEPTED`, `SUCCEEDED`, `PARTIALLY_SUCCEEDED`, `RETRYABLE_FAILED`, `PERMANENT_FAILED`,
`CANCEL_REQUESTED`, `CANCELLED`, `EXPIRED`, and `RECONCILIATION_REQUIRED`. `UNKNOWN` is
represented by `RECONCILIATION_REQUIRED` and is non-terminal. A successful
execution is immutable. A reversal or compensation is a new linked ActionProposal
and ExecutionAuthorization with its own approval, attempt and receipt chain; it
never reopens or rewrites the original successful execution.

Every claim has execution generation, lease owner/token, and monotonic fencing
token. The executor rechecks authorization, proposal version/digest, consent,
suppression, rights, budget reservation, cancellation generation, and kill switches
at claim, immediately before dispatch, immediately after response, and inside the
receipt transaction.

Claiming never grants an unconditional right to send. The `CLAIMED -> DISPATCHING`
transition atomically compares the current cancellation generation and fence and
creates one immutable dispatch permit consumed by the provider adapter. A cancel
that wins that lock produces no send; a cancel after dispatch follows the
post-dispatch reconciliation path. A definitive, non-ambiguous provider rejection
uses the bounded retry policy and becomes `PERMANENT_FAILED` when its declared
attempt limit is reached. An ambiguous attempt never consumes that limit as proof
of failure and remains `RECONCILIATION_REQUIRED` until provider evidence closes it.

Cancellation before dispatch may become CANCELLED. After dispatch it is
CANCEL_REQUESTED until no effect or provider cancellation is proven. Timeout,
lost response, stale fence after dispatch, or ambiguous result is
RECONCILIATION_REQUIRED, never inferred success/failure. Retry is allowed only
after provider lookup or idempotency proof shows duplication is safe; it keeps
rendered digest and provider idempotency key, increments attempt, and uses a fresh
lease/fence. Reconciliation-required work is never blindly retried.

`POLICY_BLOCKED` is terminal for the exact approved bytes and has no retry,
cancel, or expiry edge. A policy/content change requires a new proposal.
`retryActionExecution` starts only from `RETRYABLE_FAILED` with definitive safe
retry proof. `PARTIALLY_SUCCEEDED` requires complete per-target known results and
zero unknown effect; it is terminal but neither success nor paid value.

DecisionReceipt and ExecutionReceipt are separate immutable records. The former
contains decision/proposal IDs, version/digest, actor, capability, assurance,
quorum/conflict snapshot, reason, request/audit IDs, and absolute time. The latter
contains every attempt, provider key/acknowledgement, actual cost, timestamps,
cancellation, terminal status, and reconciliation evidence. The UI deep-links to
and retains both.

## 10. Omnichannel delivery

A channel-neutral `CommunicationIntent -> Draft -> Approval -> DeliveryAttempt ->
Receipt` model supports email, SMS, Telegram Bot, WhatsApp Business Cloud, LINE
Messaging API, Kakao BizMessage, and an explicitly configured voice provider.

Each adapter has typed configuration, verified recipient identity, consent and
suppression checks, rendered-byte digest, provider idempotency, timeout/rate-limit
handling, signed callback or poll reconciliation, delivery status, opt-out, and
synthetic contract tests. Personal-account automation and unofficial scraping are
forbidden.

Provider account, credential, approved template, sender identity, and jurisdictional
permission are deployment inputs. Missing inputs yield `UNCONFIGURED`; they never
fall back to a fake delivery. A link or button in a message starts a scoped, fresh
authorization flow and is not itself proof of actor identity.

### 10.1 Purpose and approval classes

Every communication has exactly one immutable class:

- `SYSTEM_TRANSACTIONAL`: verification, OTP, receipt, right-of-reply delivery,
  mandatory correction/retraction notice, and incident recovery generated by an
  authorized domain command;
- `SUBSCRIPTION_UPDATE`: only a human-approved public revision sent to an active
  verified subscription;
- `DISCRETIONARY_EXTERNAL`: AI/human-authored outreach, summary, request,
  recommendation, or optional external communication;
- `INTERNAL_ACTION_REQUEST`: notice that a persisted ApprovalRequest requires an
  authorized product decision.

SYSTEM_TRANSACTIONAL and SUBSCRIPTION_UPDATE do not require a second per-message
human approval, but require a versioned policy authorization, approved template,
exact recipient scope, lawful basis or consent, idempotency, cost reservation, and
delivery audit. DISCRETIONARY_EXTERNAL always requires exact rendered payload,
recipient, attachment and digest approval. INTERNAL_ACTION_REQUEST may deep-link
but its message interaction never executes the authoritative decision. A
transactional class cannot carry subscription or marketing content.

### 10.2 Communication and delivery state machines

```text
CommunicationIntent: CREATED -> POLICY_BLOCKED | MATERIALIZED | CANCELLED
CommunicationDraft: DRAFT -> AWAITING_APPROVAL -> APPROVED | REJECTED |
                    CHANGES_REQUIRED | EXPIRED | SUPERSEDED
Delivery: NONE -> QUEUED only after the current approved draft, authorization,
          activation, budget and kill-switch fences pass
          then QUEUED -> SENDING -> PROVIDER_ACCEPTED -> DELIVERED -> READ
          with RETRY_SCHEDULED | FAILED_PERMANENT | RECONCILIATION_REQUIRED |
          SUPPRESSED | CANCELLED branches
```

Response-extension requests use a separate immutable decision axis:
`NONE -> SUBMITTED -> APPROVED | REJECTED`. Submission is the existing scoped
Response Portal command and approval/rejection is the owner-addendum Control
command. Approval binds the exact request version and business-calendar version;
rejection never changes the current due time.

State never regresses. Provider acceptance is not delivery. DELIVERED/READ require
verified channel capability and signed callback or authenticated poll; email open
pixels are forbidden and never infer READ.

Logical intent dedupe is the digest of source event, purpose, topic, recipient
subject, audience-policy version, and material event version. Delivery additionally
binds endpoint, channel, locale, template revision, and rendered digest. Each
attempt binds delivery ID and ordinal, and uses the same provider idempotency data
when supported.

A timeout after possible transmission is RECONCILIATION_REQUIRED. It is not
retried or sent through fallback until definite rejection or provider idempotency
proves safety. A provider without reconciliation or idempotency cannot activate for
duplication-sensitive effects. Callbacks verify signature, time, nonce, provider
event ID, and delivery key; replay is idempotent and out-of-order evidence cannot
regress state.

### 10.3 Accountless endpoints, consent, opt-out, and fallback

Public subscribers remain accountless. Each endpoint is separately verified,
pseudonymous, and never joined to browsing analytics or another endpoint without
explicit linking consent. Endpoint states are `PENDING_VERIFICATION`, `ACTIVE`,
`REVOKED`, `BOUNCED`, and `SUPPRESSED`.

Email uses link possession; SMS uses OTP; Telegram/WhatsApp/LINE/Kakao use signed
provider user/chat binding; voice requires a verified phone endpoint plus separate
explicit grant. A number, address-book value, display name, or endpoint verification
alone is not consent.

The append-only authorization ledger binds endpoint, channel, purpose, topic/event,
policy version, source, jurisdiction, locale, granted/verified/expiry/revocation
times, and proof digest. Preferences separately bind timezone, frequency, quiet
hours, channel order, fallback permission, and cost ceiling. Authorization and
suppression are checked during audience materialization and immediately before
every attempt; revocation atomically suppresses unsent work.

Email provides signed management and one-click unsubscribe, SMS verified STOP,
chat signed unsubscribe command/button, and voice explicit opt-out. All are
idempotent receipts. Subscription opt-out does not suppress a separately justified
transactional purpose, but purpose cannot be relabelled. Fallback uses only the
recipient's explicit ordered active purpose-compatible channels, only after
definite permanent failure or reconciled SLA expiry, never ambiguous outcome. It
preserves intent/disclosure, gets a new delivery key, and respects quiet hours,
consent, suppression, cost, and kill switch.

### 10.4 Rendering, disclosure, adapters, and activation

A semantic draft has one immutable rendered artifact per selected channel.
Approval binds template ID/revision, variables, locale, attachments, destination,
disclosure class, and rendered-byte digest. An adapter may add transport framing
but never rewrite approved semantics; missing locale or template blocks delivery,
and silent machine translation is forbidden.

Each message states within channel limits what changed, why it was received,
material effect, evidence/authoritative link, relevant uncertainty, next safe
action, and preference/opt-out path. Disclosure classes are `PUBLIC`,
`INTERNAL_MINIMAL`, and `CONFIDENTIAL_LINK_ONLY`; protected evidence bodies,
responses, and sensitive titles never appear in SMS/chat/voice when confidential.

The concrete adapters are SMTP email, Telegram Bot API, Meta WhatsApp Business
Cloud, LINE Messaging API, SOLAPI SMS, SOLAPI Kakao BizMessage, and Twilio Voice.
Activation is `DISABLED | UNCONFIGURED | PENDING_PROVIDER_APPROVAL | ACTIVE |
SUSPENDED`. ACTIVE requires concrete adapter, secret reference, sender/bot identity,
provider and jurisdiction approval, DPA, approved templates, callback/poll path,
webhook secret, allowlist, rate/cost limits, kill switch, and live sandbox activation
receipt. A trait, generic HTTP client, file sink, or synthetic adapter proves no
production support. Inactive channels are not selectable or advertised.

Credentials and webhook secrets remain only at the gateway boundary. Endpoints are
field-encrypted and indexed by purpose HMAC; raw endpoint, token, secret, or body is
absent from logs, traces, metrics, audit URLs, and receipts. Every attempt reserves
worst-case cost then settles actual cost. Rate limits apply by provider, channel,
deployment, endpoint, and purpose; retry/digest/fallback cannot exceed reservation.

## 11. Trust, rights, and governance

- Every published factual claim is linked to revision-fixed, valid evidence and
  passes one typed publication gate in both application and database layers.
- Publication checks investigation state, claim/evidence coverage, source freshness,
  response window and consent, privacy, per-asset license, legal hold/restriction,
  conflict/recusal, risk-based independent quorum, and kill switch.
- No response is never framed as admission. Contrary evidence and meaningful
  limitations receive comparable prominence.
- Consent is an append-only ledger by purpose, topic, channel, policy version,
  source, and timestamp. Suppression takes effect before the next send.
- Asset rights record access, storage, model use, derivatives, excerpts,
  redistribution, commercial use, attribution, jurisdiction, expiry, and revocation;
  unknown rights permit private preservation only.
- Correction, privacy, copyright, takedown, legal, and appeal requests flow from
  public receipt through triage, SLA, reasoned decision, immutable revision or
  tombstone, and requester/subscriber notification.
- Retention, deletion/anonymization, legal hold, release, and restoration are
  executable and auditable.
- Funding, paying customers, concentration, and conflicts are disclosed. Funding
  and commercial relationships cannot influence signal generation, case priority,
  review, publication, correction, or access to public evidence.

### 11.1 Canonical publication decision

The only authorization is immutable `PublicationGateDecision`; caller `passed`, UI
state, prior test, or application-only boolean is never authority. It binds case ID
and expected version; review snapshot ID/digest; preview ID, rendered public payload
and preview digests/expiry; ordered claim revisions and claim-evidence matrix;
evidence/source revision/freshness and response-policy digests; privacy/restriction,
rights, publication consent, conflict/recusal, legal-hold, kill-switch, legal-
activation receipt-set digests; risk, policy version, quorum, counted immutable
review decisions, evaluated time, earliest expiry, outcome, and typed blockers.

The application produces the comprehensible preview; the database independently
re-evaluates the same versioned truth under the serializable `publishCase` lock.
Golden vectors require exact application/SQL parity. Disagreement is
`PUBLICATION_GATE_BLOCKED` plus alert. Projector consumes only the immutable
revision event committed by success.

Minimum quorum is the strictest applicable authority:

- LOW: one editor distinct from author;
- MEDIUM, named supplier, or reputational risk: two editors, both distinct from
  author;
- HIGH or legal-risk flag: those two plus distinct legal approval;
- whistleblower risk, non-public national-security material, or sensitive personal
  data: blocked by default; ordinary legal approval cannot silently override.

Publisher/executor is distinct and fills no review slot. Service, AI, duplicate,
recused, rejected, or changes-required decisions never count. Stable typed blockers
include `CASE_NOT_READY`, `SNAPSHOT_STALE`, `PREVIEW_STALE`,
`CLAIM_EVIDENCE_INCOMPLETE`, `SOURCE_STALE`, `RESPONSE_POLICY_UNSATISFIED`,
`RIGHTS_NOT_AUTHORIZED`, `PRIVACY_OR_RESTRICTION_BLOCKED`,
`DISCLOSURE_HOLD_ACTIVE`, `CONFLICT_UNRESOLVED`, `QUORUM_INSUFFICIENT`,
`LEGAL_APPROVAL_REQUIRED`, `LEGAL_ACTIVATION_NOT_APPROVED`, and
`KILL_SWITCH_ACTIVE`, mapped to declared external errors.

Any bound case/snapshot/preview/payload/claim/evidence/source/response/consent/
rights/restriction/conflict/funding/policy/hold/activation/review/kill-switch change
or expiry makes the decision stale. Refresh-in-place is forbidden; create a new
decision and required reviews.

### 11.2 Response, complaint, correction, and takedown

Response state remains the exact v13 axis:

```text
DRAFT -> SENT -> VIEWED -> SUBMITTED | CLOSED | EXPIRED
```

DRAFT may close before delivery. SENT means the exact approved request was accepted
by the provider; delivery truth is an orthogonal receipt. The five-business-day
clock and extension begin only from verified provider receipt or official-channel
evidence, with immutable timezone/calendar/policy/due inputs. Failure, bounce, or
ambiguous outcome starts no clock, creates a human task/blocker, and cannot be shown
as no response. Reminders are distinct idempotent deliveries. VIEWED requires a
valid scoped portal session. EXPIRED requires verified delivery, effective due time,
and extension handling; CLOSED requires typed reason and receipt.

External intake is immutable. Triage uses existing `ACCEPT | REJECT |
NEEDS_INFORMATION | DUPLICATE`; accepted correction uses existing `DRAFT -> REVIEW
-> PUBLISHED | REJECTED`; final resolution uses `RESOLVED | REJECTED | DUPLICATE |
WITHDRAWN`. NEEDS_INFORMATION creates a bounded requester task. Correction or
retraction creates a newly reviewed immutable PublicationRevision; retraction keeps
a visible tombstone and provenance. Temporary restriction records actor, reason,
scope and receipt and targets responsible review within four hours; it is not final
resolution. Material late response reopens linked correction review.

An appeal is new immutable intake linked to prior request, decision, and receipt,
never a mutation. Correction, privacy/DSAR, copyright/license, security, legal
notice, and right of reply are distinct purposes; one may create another task but
never silently closes it.

### 11.3 Communication authorization and consent

Endpoint possession, communication authorization, subscription consent, marketing
consent, and publication consent are distinct. An immutable authorization decision
binds subject/endpoint hashes, channel, purpose, topic/events, basis, policy,
jurisdiction, locale, source/origin, grant/verification/revocation/expiry, and proof.

Purposes are right-of-reply request/reminder, correction status, privacy/security
transactional notice, subscription update, and product marketing. Transactional
purposes require their own lawful-purpose decision and verified destination; they
are not subscription/marketing consent. Subscription requires exact active verified
scope; marketing requires separate opt-in; publication consent governs disclosure
only. Verification may activate only the exact pre-captured subscription intent.

Authorization/suppression runs at enqueue and pre-dispatch. Revocation appends an
event and fences unsent matching delivery. After dispatch, request cancellation
when supported, forbid retry/fallback, and reconcile without inference.

### 11.4 Asset-rights decision

Each asset revision has immutable `AssetRightsDecision` bound to asset ID/byte hash,
license or legal-basis digest, rights dimensions, jurisdiction, attribution,
reviewer, effective/expiry/revocation, version, and evidence receipt. Access,
private storage, model egress/use, derivatives, excerpt, redistribution, commercial
use, and public display are independent; one implies none other.

OCR, extraction, translation, summary, redaction, thumbnail, and other derivatives
inherit the most restrictive input right unless separately evidenced. Model use
also requires provider/data-processing activation. Unknown, expired, suspended, or
revoked rights allow private preservation only and block new model egress,
derivative, export, and publication.

Revocation blocks future use and stales approvals/gates. Existing public revisions
are not silently erased; create an impact review and choose replacement, redaction,
temporary restriction, correction, or visible tombstone through a reasoned legal
decision.

### 11.5 Retention, DSAR, legal hold, and restoration

Versioned `RecordClassSchedule` is executable configuration. Each class declares
owner, purpose/lawful-basis review, trigger, active/backup duration, locations and
derivatives, terminal action (`DELETE | ANONYMIZE | CRYPTO_ERASE |
PRESERVE_PUBLIC_REVISION`), hold and restore-suppression behavior, policy digest,
effective time, and review expiry. It binds ADR-003. Tokens delete on consumption/
expiry; response contact is retained at most one year after case closure while a
documented purpose remains; content follows its evidence/case class.

Retention requests use exact state:

```text
RECEIVED -> REVIEW -> APPROVED | REJECTED
APPROVED -> COMPLETED
```

Identity, jurisdiction policy, SLA, due time, scope, inventory, reason, reviewer,
and completion receipt are immutable. ACCESS, CORRECTION, DELETION and RESTRICTION
are distinct. Completion proves primary records, indexes, caches, derivatives,
queues and object copies were handled, with payload-free tombstone/audit.

Hold scopes have exact effects: RETENTION blocks scheduled destruction; DELETION
blocks deletion/anonymization/crypto erase; DISCLOSURE blocks public projection,
export, excerpt/model egress and external disclosure; ALL is their union. Multiple
holds union; narrower holds do not gain broader effects; holds grant no access.
Expiry creates legal review and never releases. `releaseLegalHold` binds original
hold/digest, affected IDs/scope, expected version, authority, reason, legal actor,
time, and receipt, and cannot exceed original scope.

Deletion creates restoration-suppression. Restores reapply deletion,
anonymization, revocation, suppression, and holds before service/export activation;
backup restore never resurrects accessible/processable deleted data.

### 11.6 Conflict, recusal, funding, and disclosure

Every review/external action binds immutable ConflictSnapshot for candidate author,
editor, legal reviewer, publisher, approver, and executor. It records exact
authorship/editing, case-party/recipient status, role, declared personal/family/
employment/advisory/financial/political relation, and funding/customer evidence.
Exact declared/authoritative relations may be checked; fuzzy names, address, graph
proximity, or model output never infer personal conflict.

Self-approval, case-party/recipient status, execution, and material current
employment/financial/funding/customer relationship are non-waivable for publication
and external delivery. RECUSE fills no slot and requires replacement. Unknown/stale
conflict or insufficient quorum blocks.

Funding concentration uses a versioned fiscal-year snapshot: recognized plus
binding committed revenue for the counterparty group divided by board-approved
expected annual revenue. Missing/zero denominator or disputed grouping is UNKNOWN.
Above 15% requires oversight review; above 25% board approval and enhanced public
disclosure; above 5% from an investigated subject/related party requires independent
review of every related case. Snapshot changes stale related decisions. Quarterly
funding disclosure is an immutable revision with amount/concentration band,
purpose, conflicts, policy-violation requests/outcomes, version, effective date,
approver, and superseded revision.

### 11.7 Legal and provider activation

`CapabilityActivationDecision` state is `UNCONFIGURED | PENDING_REVIEW | APPROVED |
SUSPENDED | EXPIRED`. It binds capability/environment, legal entity/controller,
jurisdiction, source/provider/sender/template/model, data class, configuration,
policy/contract/DPA/license, conditions/evidence, approver, effective/expiry and
superseded receipt digests.

Separate decisions cover public publication; each source access/storage/
redistribution mode; each model/data-egress class; each delivery channel/provider/
sender/template; privacy/DSAR; and paid-workspace processing. Applicable
prerequisites include operating entity/controller, counsel, current notices, data
map/DPIA, processor DPA/international transfer, source license, sender/template,
callback/reconciliation, and jurisdiction. Applicability and reason are recorded.

Only matching unexpired unsuspended APPROVED receipt permits production effect.
Missing/stale/mismatched approval yields UNCONFIGURED or typed blocker with no
fallback. Synthetic adapter, fixture, connection test, sandbox, sender verification,
or green health proves only itself and never production legal activation.

## 12. Business model and product loop

### 12.1 Paid job, deployment, and free boundary

The public surface earns trust and acquisition through understandable, verifiable,
citable, correctable evidence. The paid job is:

> When our team repeatedly investigates procurement records across documents and
> updates, help us produce a reviewable, reproducible evidence packet without
> rebuilding collection, extraction, comparison, collaboration, approval, and
> delivery by hand.

A paid deployment is a separate single-organization instance with its own domains,
OIDC tenant, database credentials/roles, keys, object namespaces, queues, telemetry,
source-rights configuration, roster, backup, and incident ownership. It shares no
private database, identity, key, queue, object namespace, or analytics identity with
the public editorial deployment. Customer work cannot automatically enter Gurinnae
public editorial work; public publication starts a separate independently owned
journey.

One completed paid outcome is a versioned evidence packet containing authorized
snapshot, extraction/transformation lineage, comparison/exclusions, supporting and
contrary evidence, limitations, AI proposal provenance, human decision, independent
review, and delivery/export receipt. An AI output alone is not an outcome.

The organization plan provides saved queries/cohorts, permitted multimodal batch
analysis, isolated snapshots/retention, team annotation, independent review,
exact-digest approval, scheduled export, higher API quota, signed webhook,
daily/weekly digest, SLA, and usage/quality/cost/audit reports.

Every public fact, locator, revision, correction/retraction, methodology, source
coverage/freshness, funding/governance disclosure, right of reply, rights request,
basic verified subscription, and reasonable public API/export remains free and
current. Paid value is repeatability, private authorized storage, collaboration,
approval, scale, integration, quota, SLA, and support. Payment never buys signal or
case priority, preview/delay/suppression, favorable wording, correction priority,
endorsement, or weaker gates.

Contracting and invoicing are operating records outside product UI; no checkout,
payment, tenant, or entitlement API is invented. Multi-tenancy, self-service
billing, institutional audit SaaS, and general compliance are later owner contracts.

### 12.2 North-star outcome and funnel

The north-star unit is a `Verified Workflow`. It counts once when a user/team finds
a typed procurement object or scoped dataset; sees state, freshness and a material
limitation; opens revision-fixed evidence or reproduction; and completes a
responsible outcome—public citation/export/subscription/correction, or paid
persisted snapshot plus human-approved evidence packet/delivery receipt. Synthetic
fixtures, setup, page views, failed jobs, raw signals, and unreviewed AI output do
not count. Deduplication stores no raw search/response/token/email or long-term
public profile.

`Monthly Verified Workflows (MVW)` is the north-star metric. Commercial companions
are paid MVW per active organization, time to first paid MVW, variable cost per paid
MVW, and contribution margin.

- Public acquisition: privacy-safe search, stable citation, referral, or method
  content reaches a relevant public object.
- Public activation: one public Verified Workflow.
- Organization acquisition: a qualified organization with recurring job,
  authorized data, buyer, operational owner, independent reviewer, budget and trust
  acceptance enters a scoped pilot.
- Organization activation: first strict paid Verified Workflow after DATA_READY;
  on-time is at most 168 hours and the P90 objective is at most 336 hours.
- Fixed retention: at least two additional distinct strict paid-workflow roots in
  `[activation_at+29d, activation_at+57d)`.
- Revenue qualification: current contract/invoice plus at least one verified cycle
  in trailing 30 days; signed but unprovisioned/inactive contracts are separate.

Initial thresholds: public anomaly-versus-wrongdoing plus limitation recognition at
least 90%; exact locator within two minutes at least 90%; qualified pilot activation
at least 80%; activated-pilot days 29–56 retention at least 70%; pilot-to-paid at
least 30%. Before five eligible organizations, report counts and intervals rather
than a misleading rate. Every metric has versioned formula, population, exclusions,
timezone, window, owner, source, freshness, threshold, and action on breach.

Except for the append-only human `QUALIFIED` receipt, commercial stages are
deterministic as-of projections and have no stage row or stage event. `AT_RISK` is
an overlay, not a stage; inactivity alone never proves `CHURNED`. A churn requires
a terminal contract leaf and no active or suspended successor. Re-entry starts a
new qualification episode and never rewrites the old cohort.

### 12.3 Pricing metric and unit economics

There is one initial organization SKU:

```text
monthly charge = workspace base
  + active-contributor blocks
  + processing-credit overage
  + storage GB-month overage
  + API Record Unit overage
  + optional SLA add-on
```

Base includes ten active contributors plus read-only viewers; added contributors
come in blocks of ten. One API Record Unit is 1,000 normalized records returned.
Processing credits use a versioned job/provider catalog; every AI/OCR job shows and
reserves maximum credit, then settles actual. Storage is average encrypted GB.
Webhook/digest has included quota. Case, signal, publication count, subject identity,
and sensitivity are never price metrics.

Actual KRW price, quota, public-interest discount, tax/invoice provider and SLA price
are deployment business inputs. Configured price must achieve at least 60% variable
gross margin at P75 pilot usage and 70% for general availability. A lower pilot
price needs oversight reason/expiry. Billable/invoice reconciliation is 100%, cost
capture at least 99%, activated support at most four hours/month, and measurable CAC
payback at most 12 months.

Fully loaded workspace cost includes compute, database/WAL, storage, egress,
model/OCR, search, delivery, observability, support, human review, and workload-
specific legal/security cost. Required units include raw record, normalized line,
OCR page, analysis job, cohort rerun, evidence packet, API Record Unit, GB-month,
1,000 delivery attempts, support hour, and material-correction hour. Missing cost is
UNKNOWN, not zero. Cost failure changes price/quota/efficiency, never evidence,
privacy, correction, or approval gates.

### 12.4 Commercial trust firewall and channel rollout

Billing/customer/funder identifiers are unavailable to public detection and
editorial priority inputs. Paid identity, roles, database, objects and retention are
isolated. Tenant data is not reused for public investigation, model training, or
cross-deployment analysis. Customer output is labelled and never an official
Gurinnae finding. Related cases require disclosure, recusal, independent review,
and concentration guardrails. Entitlement, export, delivery, discount and conflict
changes are audited.

The first SKU defaults to Public Web, verified email, API/export, signed webhook,
and daily/weekly digest. SMS, Telegram, WhatsApp, LINE, Kakao, and voice are concrete
deployment-gated adapters, not automatic launch entitlements. Each needs its exact
provider/legal/consent/cost activation; UNCONFIGURED does not block the first sale
but cannot be advertised or counted as operational.

Only privacy-safe allowlisted first-party events and authoritative receipts feed
product metrics. Response/evidence/search content, tokens, filenames, sensitive
identifiers, and cross-session public identity are forbidden. Analytics failure
never blocks a core task.

## 13. Operational truth

- Unobserved is `UNKNOWN`, not healthy. Status is derived from current dependency,
  heartbeat, queue, freshness, budget, and telemetry evidence.
- Every external side effect is bounded, idempotent, fenced, observable, and
  reconcilable.
- Paid provider use requires an atomic daily/monthly reservation and settlement.
  Missing cost data is not zero cost.
- Connector success requires all declared pages/windows and durable checkpoints;
  partial collection is not success.
- Workers renew leases, use bounded concurrency, drain on shutdown, and preserve
  exactly-once business effect under redelivery.
- Scoped kill switches for source, model, publication, delivery channel, and public
  serving are evaluated at every relevant boundary and propagate within the SLO.
- Production readiness includes OTLP telemetry, actionable alerts, capacity tests,
  encrypted/versioned object storage, PostgreSQL PITR, projection rebuild, and
  restore drills inside documented RPO/RTO.

### 13.1 Operational state and SLO accounting

Required heartbeats occur at least every 30 seconds and stale after 90 seconds.
OPERATIONAL requires every required signal fresh, critical dependencies ready, and
no blocking incident. Optional failure is DEGRADED; critical dependency/hard-gate
failure is INCIDENT. Missing required telemetry is internal UNKNOWN and opens a
telemetry-gap incident. Because the public enum lacks UNKNOWN, public-relevant
unknown maps to incident with “status verification unavailable,” never operational.

Liveness proves loop alive; readiness is admission for database, configuration,
migration, lease and capability dependencies. Aggregate status is the worst
capability. Every status carries as-of, signal times, build revision and incident/
gap IDs. Availability uses UTC month; latency is by operation ID at service boundary;
maintenance is not silently excluded. Burn alerts are 14.4x over 5m/1h and 6x over
30m/6h. Release targets are SPEC-CONFLICT-006.

### 13.2 Budget reservation and kill-switch containment

Every paid provider attempt has one PostgreSQL reservation keyed by job, attempt,
provider candidate, and pricing version. State is `RESERVED | SETTLED | RELEASED |
RECONCILIATION_REQUIRED`. Under locked applicable ledgers:

```text
available = limit - settled billable cost - all nonterminal reservations
```

Worst-case cost is reserved before egress across environment/provider/case daily
and monthly caps. Insufficient cap yields `PAUSED_POLICY/BUDGET_BLOCKED` and zero
call. Each fallback needs its own reservation. Output validity gates application,
not accounting: all billed usage settles even for invalid/abstained output. Missing
usage/price is never zero; hold reservation in reconciliation and block dispatch
when remaining cap is unprovable. Actual above reserve records full cost, opens
incident, and fences that provider. Overrides bind amount/currency, reason,
approver, scope, expiry, and receipt.

Kill-switch scopes are GLOBAL, SOURCE, MODEL_PROVIDER, RESPONSE_ATTACHMENT,
PUBLICATION, DELIVERY_CHANNEL, PUBLIC_EXPENSIVE_ENDPOINT, and PUBLIC_SERVING. The
most restrictive match wins. Monotonic state reaches every admission and
pre-side-effect boundary within five seconds. It is checked before authorization
outbox, claim, dispatch, retry/fallback, publication commit, and projection serving.
Queued work becomes policy-blocked. Activation after dispatch permits receipt,
reconciliation, cancellation, suppression, opt-out and compensation but no new
attempt/fallback. Unknown/stale/unreadable switch state fails mutation and egress
closed. Deactivation never auto-requeues; explicit authorized retry is required.
Broad switches need two-person approval and immutable activation/extension/expiry/
deactivation receipts.

### 13.3 Connector completion, leases, and side-effect fencing

A source run is source, operation, partition, window, connector-contract version,
and run ID. Every page/cursor is raw-persisted before parse and receives canonical
request hash, response hash, position, item count, reported total and next position.
Traversal ends only at the operation's terminal condition. Repeated cursor,
identity inconsistency, unexplained total shrink, malformed terminal metadata, or
missing page makes run non-successful and opens incident.

Page receipt may advance resumable work position, but authoritative watermark moves
only after every page/window is durable, parsed, reconciled and successful. Crash
replays durable evidence with remote identity/revision dedupe and does not advance
window checkpoint. Retry exhaustion atomically records terminal run, DLQ, incident,
and unchanged checkpoint.

Every job claim has unique lease token and monotonic fence, renewed before one
third TTL. Claim, renew, completion, checkpoint, outbox, and side-effect receipt
compare both. Renewal failure cancels handler and forbids later authoritative writes.
Provider attempt is recorded before send, then acknowledgement/reconciliation after.
Timeout after possible acceptance is reconciled, never blindly resent. Shutdown
stops claims, drains/cancels by policy, relinquishes leases, fences effects, and
flushes telemetry.

### 13.4 Capacity and recovery profile

Capacity uses at least 20 million normalized rows, 100,000 signals, 1,000 active
cases, and representative indexed evidence/search. Public traffic runs 30 minutes
at 100 requests/second with declared cache mix, then ten minutes at 150. It meets
canonical SLO with at most 0.5% server errors and no unbounded queue, memory,
connection, or retry growth. A one-million-record connector replay finishes within
24 hours with zero omitted page/window and identical idempotent replay digest.

All application pools consume at most 70% of PostgreSQL max connections; 20% is
reserved for admin/migration/incident/recovery and 10% headroom. Overload uses
bounded admission and Retry-After, never unbounded memory or connections.

Authoritative PostgreSQL RPO is at most five minutes and RTO four hours. Objects
referenced by active publication are versioned, encrypted, protected and hash-
verified with logical-loss RPO zero and RTO four hours. Replayable raw objects have
RPO/RTO 24 hours. Public projection rebuild completes within two hours after restore.

Monthly sampled point restore and quarterly clean full restore verify case/version/
approval, public pointer, audit/outbox gaps, object versions/hashes, projection,
stale leases, retention/holds and zero duplicate business effect. Receipt records
requested/available recovery point, actual RPO/RTO, versions, source commit and
assertion hashes. Backup existence without restore receipt is not readiness.

### 13.5 Incident lifecycle and operating ownership

Incident lifecycle is `DETECTED -> TRIAGED -> CONTAINED -> RECOVERING -> RESOLVED
-> POSTMORTEM_CLOSED`, each with owner, evidence, affected capability and next
update. SEV0 acknowledgement/commander/containment targets are 5/10/15 minutes;
SEV1 15/30/60; SEV2 acknowledgement four hours; SEV3 next business day. Public
SEV0/1 holding update occurs within 30/60 minutes and every 30/60 minutes. Required
telemetry gap starts SEV2 and escalates to affected capability severity. Resolution
requires restored SLO, reconciliation, evidence, owner approval and remediation;
SEV0/1 review is due five business days.

| Function | Accountable for | Cannot do |
| --- | --- | --- |
| Product/PdM | journey outcome, metric dictionary, research, scope and launch recommendation | waive evidence, editorial, legal, privacy or ops gates |
| Editorial duty | triage, investigation, response, correction, publication and content truth | prioritize/suppress for revenue |
| Independent review/publisher | exact decisions, recusal and publication receipt | self-approve or reuse stale decision |
| Data/Engineering | sources, parsing, detection, agents, lineage, quality and replay | approve factual publication |
| SRE/on-call | availability, queues, providers, budget, incident, switches and recovery | call unknown healthy or bypass content gate |
| Legal/Privacy | rights, consent, holds, privacy and conditions | replace editorial fact finding |
| Sales/CS/Finance | qualification, isolated onboarding, support, invoice, renewal and cost | influence signals, cases, review, correction or public access |

Small teams may share people, never required role separation. Every critical
function has named primary/backup and escalation. A capability is operational only
with owner, visible state, capacity/SLA, alert/dashboard/runbook/support, auth/
consent/rights/retention/budget/switch/reconciliation policy, contract and eligible
live preflight receipt, incident/rollback/recovery proof. Otherwise it is
UNCONFIGURED or BLOCKED.

Cadence is daily source/queue/deadline/provider/incident/budget; weekly journey
failures, blockers, research, AI quality, data quality and capacity; monthly
activation/retention/revenue/unit cost/support/churn/trust; quarterly concentration,
rights/policy, restore, accessibility and continuation/stop. Scale-up requires all
hard gates, task thresholds, ownership, support/incident paths and no trust breach.

### 13.6 Unit-economics fact model

Useful verified outcomes are terminally receipted triaged signal, independently
reviewed investigation, accepted proposal materialized by one typed command,
audited delivery, completed organization decision cycle, or publication/correction.
Calls, drafts and raw signals are not outcomes. Direct cost attaches by job/run/
case/workspace and price version; shared compute/database/search/observability/
support uses measured drivers; human/legal uses purpose-limited time. Unallocated
cost remains visible UNKNOWN. One hundred percent of direct and at least 95% of
total cost must be allocated before margin/pricing claims. Revenue links only at
organization/contract/period and never changes editorial priority.

## 14. Acceptance and evidence

The following are release-blocking:

- all 271 authority scenarios execute their mapped tests exactly once with no skip,
  zero-test, missing path, duplicate receipt, or unverified environment;
- every unique operation in the source-derived effective external, private
  Identity, private session-broker and communication-callback registries has real
  handler, application, persistence, contract, consumer where applicable, and
  runtime integration evidence; the receipt records the derived per-registry and
  union counts rather than comparing only a handwritten total;
- all 94 screens have typed view-models plus authenticated/scoped success and every
  required empty/partial/stale/error/conflict/access state;
- critical journeys use non-empty data through PostgreSQL, services, SvelteKit,
  browser, and receipt, not mock-only or fixture-only production paths;
- public projections are written by production event paths and rebuilt deterministically;
- all expert gates in `implementation-evidence/expert-review-status.md` are current
  `LGTM` for the exact reviewed commit and evidence bundle;
- `make verify-final`, clean extraction, deterministic archive, backup/restore,
  capacity, accessibility, and external-adapter preflight gates pass.

Each acceptance receipt records scenario ID, test path, exact command, environment
digest, source commit, exit status, assertion count, duration, and hashes of logs,
screenshots, traces, or artifacts. Mapping declarations are not execution evidence.

### 14.1 Authoritative acceptance runner

`make verify-acceptance` is the only aggregate entrypoint and an unconditional
dependency of `make verify-final`. It verifies the byte-immutable v13 base lock,
then reads the source-derived effective executable registry and scenario-ID
precedence overlay; it never rewrites the 35 base feature files, base catalog, or
base mapping. The registry separately preserves the 271 base and 168 supplemental
identities and their 439-row union. It rejects any undeclared acceptance test in
declared targets and requires set equality across feature IDs, registry rows,
discovered tests, started/terminal tests, and external receipts for each base,
supplemental, and effective set. Supplemental IDs cannot replace or double-count a
base scenario.

Every feature is compiled into NFC-normalized Background and scenario clauses,
resolved Given/When/Then phases, Examples rows, placeholder-expanded clause
instances, and deterministic oracle contracts. Clause text/order, Background
membership, Examples header/value/order, or expansion drift changes the scenario
contract digest. Runtime observations must be exact-set equal to those compiled
instance and oracle pairs; one generic assertion cannot stand in for a scenario.

`crates/test-support` remains one of 32 base workspace members and owns package name
`gurine-acceptance-tests`; no extra base member is added. It exposes 28 integration
targets for 202 Rust scenarios. Seven Playwright files own 69 scenarios. Discovery
must find exactly one test per scenario before execution.

Rust registration is a bijection: authority ID `AC-FOO-BAR-001` is the exact
nextest test name `ac_foo_bar_001` (ASCII lowercase and every hyphen replaced by
one underscore). Discovery uses nextest's machine-readable list and selection uses
the exact expression `test(=ac_foo_bar_001)`; substring filters are invalid.
Playwright titles begin with exactly `[AC-FOO-BAR-001]` followed by one space, and
selection uses an anchored escaped grep. Discovery records the fully qualified
project/file/title and must find one match before execution.

All execution after dependency preparation runs without download in a hash-pinned
environment with Rust 1.97.0, cargo-nextest 0.9.140, Bun 1.3.14, locked
Playwright/browser digest, and PostgreSQL 18.4. AC-DEPENDENCY_PINNING-007 is the
only network exception: two disposable clean bootstrap sandboxes receive an empty
dependency cache, an allowlist limited to the lockfile's declared registries, and
no application/runtime secrets. They record DNS destinations, downloaded artifact
digests, lockfile/tool/image digests and output cache digests; equality is asserted,
then both sandboxes are destroyed. No other acceptance process inherits their
network namespace or writable cache. Validator checks path, package/target,
scenario registration, aggregate gate, tool pin, egress receipt, and receipt schema
rather than non-empty strings.

### 14.2 Real-environment proof

Mapping environment is normative. One clean full synthetic Compose stack uses the
real migrated PostgreSQL, internal services/workers, production SvelteKit builds,
generated clients, browser and receipts. Internal API, persistence, worker,
projection or BFF cannot be mocked. Fixtures may establish input/precondition but
cannot write the effect under test or serve as asserted result. Direct SQL may set
only prerequisites; action/outcome traverse production domain/application. Declared
synthetic provider is allowed only at external network boundary and is named in the
environment receipt.

### 14.3 Immutable receipts and fail-closed execution

Each run creates a non-overwritable external evidence directory. Static mapping and
design registries contain no implementation status, missing count, release state,
or execution receipt. Each canonical scenario receipt contains
schema/run/scenario/feature/title and compiled Gherkin/oracle digests;
implementation path and canonical argv selector; authority ZIP, design bundle,
member manifest and mapping SHA-256; clean commit/tree, candidate archive and clean
extraction digest; environment/Compose/image/tool/PostgreSQL/migration digests;
start/duration/attempt/status; exit/discovered/started/terminal/passed/failed/
skipped/retried/assertion counts; exact runtime-layer receipts; and SHA-256, byte
size and media type for every log, trace, screenshot and artifact.

A sorted aggregate index hashes the 271 base and 168 supplemental receipts and
their 439-row union. Release requires unique set-equal IDs, attempt 1, PASS, exit
zero, discovered/started/terminal/passed one, failed/skipped/retried zero, positive
assertion count, and verified artifacts. `skip`, `fixme`, `pending`, `quarantine`,
`#[ignore]`, focused/only, missing path, duplicate ID, zero test/assertion, timeout,
crash, worker loss or infrastructure failure is terminal failure. Authoritative run
has zero retries. Diagnostic rerun gets a new run ID and never overwrites or converts
failed evidence.

### 14.4 Clean-extraction completion order

The release proof is non-circular. Development checks may run repeatedly but are
not authoritative receipts. One clean source commit proves completion in this
order:

1. run `make verify-prearchive`, which performs source/static/build checks but does
   not run or claim the 271-base/168-supplemental authoritative acceptance sets;
2. create a candidate deterministic source archive twice and require byte identity;
3. extract one candidate into a new empty directory and verify sidecar, manifest,
   source-tree digest and zero dependency/build/evidence residue;
4. from that extraction, run the single authoritative `make verify-final` into a
   fresh external evidence root, passing the candidate archive SHA-256 and
   extraction-receipt SHA-256 as immutable inputs;
5. AC-FINAL_DELIVERY-001 consumes those inputs and verifies the current extracted
   tree; it never searches for an archive that has not yet been created;
6. require the fresh set-equal base, supplemental and 439-row union receipt indexes
   to be bound to the extracted tree/design/archive digests;
7. obtain all implementation LGTM verdicts against that exact commit and evidence.
   If any source changes, discard the candidate and all verdicts and restart at 1;
   otherwise the already-proven candidate is renamed final without byte change.

No original receipt, cache, service state or test result satisfies extraction.
Later source, test, mapping, migration, Compose, image or design change stales
acceptance and affected verdicts. `ARTIFACT_READY` also requires a clean worktree.

### 14.5 Supplemental AI/action/channel/domain verification

Supplemental acceptance covers every exact tool and agent ID in the effective
catalogs with real adapters, exact prompt/schema and multi-turn loops; HTML,
PNG/JPEG/WebP/TIFF, WAV and WebM plus all v13 parser goldens; every declared
rule's snapshot byte-equivalent replay after core mutation; citation valid/stale/
outside/locator/hash cases with zero partial proposal; every proposal transition and
one-command-one-target; approval-before-side-effect; every concrete channel
unconfigured/consent/suppression/timeout/duplicate/out-of-order/reconciliation/
kill-switch/stale-fence path; every domain state edge and individual guard; every
mutating command's missing/exact identity, stale/two-writer/replay/changed-byte/
rollback/audit/outbox cases; and removal of each required persisted field proving no
synthetic UUID/time/enum/count/digest/recipient/cost/health/receipt appears.

The closed journey additions have at least these exact executable acceptance IDs:

```text
UX-JOURNEY-J-10-ENTRY-TO-PROMOTED-EVIDENCE
UX-JOURNEY-J-10-CANCEL-RECONCILE
UX-JOURNEY-J-10-CITATION-PROMOTION-DIGEST-PARITY
UX-JOURNEY-J-11-ENTRY-TO-DURABLE-EFFECT
UX-JOURNEY-J-11-DECISION-BRANCH-SEPARATION
UX-JOURNEY-J-11-WITHDRAWAL-RACES
UX-JOURNEY-J-11-CANCEL-DISPATCH-RECONCILE
UX-JOURNEY-J-11-ORIGIN-RECEIPT-RETURN
UX-JOURNEY-J-12-QUALIFIED-TO-FIRST-PAID-VALUE
UX-JOURNEY-J-12-ACTIVATION-BOUNDARIES
UX-JOURNEY-J-12-RETENTION-FIXED-WINDOW
UX-JOURNEY-J-12-AT-RISK-CHURN-CORRECTION
UX-JOURNEY-J-12-NO-STAGE-LEDGER
DB-JOURNEY-HANDOFF-ONE-OPEN
DB-JOURNEY-HANDOFF-OWNER-SWITCH-ONLY-ON-ACK
DB-JOURNEY-HANDOFF-REASSIGNMENT-HISTORY
EVENT-JOURNEY-HANDOFF-REPLAY-GAP
ROUTE-JOURNEY-EXACT-94-UNCHANGED
```

## 15. Change control and completion

A material change to journey, business rule, approval, publication, consent,
rights, schema, provider, public API, or revenue boundary requires a decision-complete
design change and independent review before implementation. Review follows
`implementation-evidence/expert-review-prompt.md`.

### 15.1 Current open closure ledger

Every item below is open at this document's steering date. The detailed stable
finding IDs in `implementation-evidence/reviews/` and
`implementation-evidence/expert-review-status.md` remain required; this summary
does not close or replace any of them.

| ID | Open condition | Close only when |
| --- | --- | --- |
| AXIS-OPEN-001 | Additive totals and the current design digest are declaration-driven and omit linked design inputs. | Canonical registries are set-equal, every total is source-derived, the complete manifest below validates, and all reviewers bind its digest. |
| UX-OPEN-001 | Much of the 94-screen matrix is generated/generic; commands, state occurrences, focus targets and critical journey edges are not semantically reachable. | Every screen passes §5.2 with realistic typed data; every mutation is action-reachable; RSP response/appeal, publication/review, evidence and operations journeys have executable forward, receipt and recovery paths. |
| AI-OPEN-001 | Agent/tool/provider contracts, Internet source-use joins, artifact promotion, multimodal parsers and CAS analysis view-models are incomplete. | Every catalog ID has a closed schema and real adapter; every required format has real fixtures; artifact-to-evidence promotion is human-receipted; CAS-010/011 render typed analysis, provenance, visualization and next action. |
| DATA-OPEN-001 | Warehouse lineage, search projection and visualization can still be claimed by opaque JSON or independently transformed chart/table data. | PostgreSQL/object membership, source-use/citation joins, deterministic projection, `VisualizationVm`, accessible table and exact digest equality are executable end to end. |
| CMD-OPEN-001 | Additive command, persistence, event payload, consumer, approval and execution lifecycle closure is incomplete. | Every source-derived command/event has exact lock/order/cardinality/state/audit/outbox/receipt schema, one owner and executable replay/race/failure acceptance; no generic materializer remains. |
| DB-OPEN-001 | Additive database addenda are not yet proven by complete runtime migrations and physical cross-addendum validation. | The source-derived migration sequence creates/alters every declared relation, closed JSON type, FK/candidate key, check, index, trigger, RLS and procedure; fresh PostgreSQL migration, concurrency, rollback and boundary tests pass. |
| SESSION-OPEN-001 | Appeal, communication-profile, endpoint version, consent, callback replay and provider-native receipt/session contracts are not one closed authority graph. | Token-free BFF derivation/rotation, exact scope binding, versioned endpoints/configs, request-level callback replay, multi-item receipts, consent/suppression and provider golden fixtures pass without widening a parent session. |
| TRUST-OPEN-001 | Privacy requests, retention/restoration, non-case legal holds, rights, conflict/funding, response/appeal, correction/retraction and publication gates have unresolved bindings. | Each lifecycle has typed intake/status/decision/effect/appeal, independent owner, immutable provenance, exact UI action and receipt; rights/hold/privacy/publication fences are enforced on every effect path. |
| BIZOPS-OPEN-001 | Funnel, paid outcome, tariff/invoice/revenue membership, cost allocation, scheduler/provider resilience and live readiness are not yet runtime facts. | Acquisition-to-retention facts are privacy-safe and receipted; only terminal valuable outcomes count; decimal/FX/period rules reconcile; SLO, scheduler, budget, backup/restore, rollback, alert and support receipts are current. |
| PROCUREMENT-OPEN-001 | Procurement semantics can still collapse anomaly into wrongdoing or hide cohort, unit, VAT, cancellation, supplier/entity and source-revision decisions. | A procurement-domain reviewer reproduces each rule from immutable facts and confirms typed Korean procurement vocabulary, comparability/exclusion, counter-evidence, response and public-safe interpretation across UI/API/DB/tests. |
| QA-OPEN-001 | Current acceptance, migration, full-stack, accessibility, usability and clean-extraction evidence does not prove the effective design. | Every base and supplemental ID is discovered and executed exactly once with zero skip, real production boundaries, immutable receipts, same clean commit/design/archive digest and all hard gates green. |

No row may be closed by changing its wording, reducing a catalog, accepting a mock,
or moving the behavior to a deployment note. A genuinely deployment-gated adapter
may remain `UNCONFIGURED`, but its contract, activation gate, negative paths and
truthful UI must still be implemented and verified.

### 15.2 Canonical design bundle and staleness

The design-bundle digest uses the exact V2 length-delimited byte algorithm below;
it is not the digest of a rendered text manifest. Paths are UTF-8 repository-
relative POSIX paths sorted bytewise. Members are unique regular files inside the
repository and file bytes are never normalized.

```text
SHA256(
  "GURINNAE-DESIGN-BUNDLE-V2\0" ||
  repeated(
    u32be(path_utf8_length),
    path_utf8,
    u64be(exact_file_byte_length),
    exact_file_bytes
  )
)
```

The separately rendered member manifest records each category, path, byte length
and lowercase SHA-256 plus the authority ZIP SHA-256, schema version and selection
rule; its own SHA-256 is a second binding, not the bundle algorithm. The selector
fails if a required path is missing, a selected member is a link/special file, an
unregistered normative addendum exists outside the selection, or runtime execution
evidence is found inside the source tree.

The included set is, at minimum:

- `DESIGN.md`, `implementation-evidence/spec-conflicts.md`, the common expert
  prompt, screen closure, domain closure and source-derived inventory reports;
- every owner/product operation, command, persistence, event, state-machine,
  resource/error, approval and session addendum;
- every UI navigation/action, section/surface, state-profile and semantic-closure
  contract used to build a screen;
- every agent addendum schema/runtime/provider/provenance file, the required parser
  multimodal addendum and its schema/fixture manifest;
- every database addendum fragment/global catalog and physical creation-order
  contract; and
- every supplemental design acceptance feature or registry for AI, multimodal,
  actions, channels, states, accessibility, usability, business facts and
  procurement semantics.

Review reports, status tables, timestamps, generated verdict prose, runtime logs
and implementation receipts are excluded to avoid a circular digest. They bind the
digest as outputs. Any included-byte or selected-path change creates a new digest
and makes every design verdict `STALE`; there is no role-by-role exception at the
design gate.

### 15.3 Independent specialist `LGTM` loop

The mandatory design-review roster is below. Existing legacy gate names may map to
these roles only through an explicit one-to-one review manifest; combining reports
must not omit a question or independence requirement.

The machine-readable canonical roster and one-to-one legacy alias map is
`implementation-evidence/expert-review-roles.yaml`. The table below and every
prompt, status matrix and freeze record are projections of that registry; the
freeze validator derives its required set from the registry and rejects any
missing, duplicate, renamed or extra canonical role.

| Role | Blocking question |
| --- | --- |
| PdM | Are the core journeys connected from entry to durable outcome, understandable, measurable, owned and operable? |
| Product/information design | Does each screen expose the right object, hierarchy, evidence, uncertainty and action with consistent visual language? |
| Responsive/accessibility | Is every state usable at compact through wide, zoom, keyboard and screen reader with deterministic focus/error/recovery behavior? |
| Business model | Do target customer, valuable job, acquisition, activation, retention, revenue, cost and trust firewall reconcile to authoritative facts? |
| AI/multimodal/Internet research | Do authorized real inputs traverse typed tools/providers/parsers, citations, abstention and human promotion without invented evidence? |
| Data/search/visualization | Are warehouse membership, lineage, retrieval, projection, chart/table semantics, uncertainty and digest equality exact and reproducible? |
| Database/Rust domain | Do physical schema, constraints, transactions, typed states, repositories and concurrency make invalid domain states unrepresentable? |
| Command/event/lifecycle | Does every mutation have one exact command, persistence effect, event, consumer, replay rule, owner and terminal/recovery path? |
| Human approval | Is the exact common subject independently decided, quorum-bound and separated from fenced execution and reconciliation? |
| Omnichannel/session | Are identity, scoped session, consent, endpoint/config version, rendering, provider callback, opt-out and receipt closed per channel? |
| SRE/FinOps | Are observed health, capacity, scheduler, provider fallback, budget/cost, kill switch, incident, restore and rollback production-operable? |
| Trust/privacy/legal | Are publication, response, correction, rights, privacy, retention, holds, conflicts, funding and legal activation fail-closed and auditable? |
| QA/traceability | Does executable evidence prove every effective ID and hard gate once, without placeholder, fixture-only effect, skip or false green? |
| Procurement domain | Are Korean procurement facts, comparability, entity/source revision, anomaly wording, counter-evidence and investigation decisions domain-correct? |

For one frozen digest, assign each role to a read-only independent reviewer that did
not author the material it reviews. Each report includes role, exact digest, inputs
checked, stable finding IDs, prior-finding retest and `LGTM` or
`CHANGES_REQUIRED`. Missing evidence is `CHANGES_REQUIRED`; a majority vote cannot
override one blocking specialist.

The implementation owner groups compatible root causes, resolves conflicts through
§0.1, updates the complete contract and validators, and creates a new digest. That
change makes every prior design `LGTM` stale, so the full roster reviews again.
There is no arbitrary iteration limit. Repeat until every role independently says
`LGTM` on one identical digest, or an explicit owner decision/external authority is
truly required and the safe blocked state plus exact question is reported. After
design `LGTM`, implementation reviews repeat against one clean commit and immutable
evidence bundle; a design verdict never substitutes for runtime proof.

`ARTIFACT_READY` is allowed only when every hard gate and every expert gate is
current and green for one source tree. An archive, CI badge, review comment, or
manifest is never sufficient by itself. The repository's PR is not merged directly
by an agent.
