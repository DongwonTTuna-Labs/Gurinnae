# Gurinnae Trust, Privacy, Legal, Editorial, and AI Review R1

VERDICT: CHANGES_REQUIRED

## Reviewed state

- Review mode: independent, read-only source and contract audit
- Files changed by review: none outside this evidence report
- Reviewed Git HEAD: 0f7c7bed625d8e0b55e285285c218cb05e0957ef
- Branch: codex/complete-v13-source
- Worktree state: modified and untracked current-design addenda were included in the review
- Worktree status fingerprint: 2193784235bbd335ff57c783191f82f6c979f7c7ee938665951a3f5551a9fd35
- Authority archive SHA-256: 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5
- Current design bundle digest: 284130fcfb90d5da689ee0815ce08cd1d1ec55e76f91cd671c457d85262ccb21
- DESIGN.md SHA-256: 058f3893a7953ac547dc406194a9435854621142edd44ebc5d71d8b7867daa71
- Domain closure SHA-256: 11f9b13c6651e4f0310f7e05eccc7413352f5834fa183dfbf809651f58aefda1
- Screen closure SHA-256: 067717f75a97624175c89d33b4b869ef387a3a2f99d225523bc4e2afc27eeff8
- Review date: 2026-07-15 UTC

The current bundle digest is not a complete review pin. scripts/design_bundle_digest.py:9-28 omits the database addenda, agent schemas, copy policies, and several acceptance contracts reviewed below. Any change to a cited file invalidates this verdict and requires a new independent review.

## P0 findings

### TPL-R1-P0-001 — Privacy-rights intake and requester status are not executable

Evidence:

- specs/product/addendum-operation-contracts.yaml:563-595 declares create, exchange, and status operations.
- specs/database/migrations/0024_v13_submission_session_boundary.sql:11-18 has no privacy-request session kind or scope.
- specs/database/addendum/0028-governance-operations.yaml:274-295 lacks the receipt-token hash, consumed-at value, status-session relation, and identity-proof binding.
- specs/database/addendum/0028-governance-operations.yaml:1606-1609 records the same issue as blocking.
- specs/ui/screens/PUB-031.md:51-65 still exposes only a generic contact path.

Root cause:

The product contract added HTTP operation names without closing the session, persistence, identity-proof, requester-safe receipt, and visible screen-action graph.

Required acceptance evidence:

- A PRIVACY_REQUEST_STATUS session kind and PRIVACY_REQUEST scope.
- An atomic one-time token exchange that issues an HttpOnly status session and records token consumption.
- Cross-request, replay, expiry, wrong-issuer, and token-in-URL/log/analytics negative tests.
- A real privacy-rights wizard, status re-entry, typed outcome view, and keyboard/mobile E2E.

### TPL-R1-P0-002 — ACCESS, CORRECTION, DELETION, and RESTRICTION are collapsed into one destructive retention flow

Evidence:

- DESIGN.md:1021-1024 distinguishes the four rights.
- specs/product/addendum-state-machines.yaml:132-139 applies one transition model to all four.
- specs/product/addendum-resource-error-contracts.yaml:663-686 exposes mixed terminal actions.
- specs/database/addendum/0028-governance-operations.yaml:799-930 requires destructive suppression and zero active hold coverage for the shared flow.

Root cause:

The implementation models a privacy request as a retention job instead of a request-type discriminated lifecycle with different effects and legal-hold semantics.

Required acceptance evidence:

- An immutable request inventory or encrypted capsule/member ledger.
- ACCESS produces a disclosure package and withholding/redaction reasons.
- CORRECTION produces append-only correction facts and receipts.
- DELETION records per-location deletion, anonymization, crypto-erasure, lawful exceptions, and restore suppression.
- RESTRICTION records scope, effect, review date, and release receipt.
- Hold-effect matrix tests distinguish DISCLOSURE from RETENTION and DELETION.

### TPL-R1-P0-003 — Retention completion has contradictory state and event owners

Evidence:

- specs/product/addendum-state-machines.yaml:139 lets transitionRetentionRequest complete the flow and emit retention.execution_completed.v1.
- specs/product/addendum-event-contracts.yaml:105 names retention-worker as producer.
- specs/database/addendum/0028-governance-operations.yaml:785-787 reuses that event for the decision rule.
- specs/database/addendum/0028-governance-operations.yaml:1602-1605 records the contradiction as blocking.

Root cause:

Worker execution and human/control decision were represented as the same terminal fact.

Required acceptance evidence:

- Either a worker-owned immutable execution receipt followed by a control decision event, or one explicitly worker-owned completion path with external COMPLETE removed.
- Exactly-one outbox/event cardinality, retry, stale decision, and 64-client race tests.

### TPL-R1-P0-004 — Non-case legal holds cannot be placed and restore can resurrect deleted data

Evidence:

- specs/database/addendum/global.yaml:128-132 requires typed non-case coverage anchors.
- specs/database/addendum/0028-governance-operations.yaml:1504-1521 does not include such an anchor in its declared relation inventory.
- specs/api/operation-contracts.yaml:22030-22059 and db/migrations/0006_operational_closure.sql:16-22 permit only CASE, PUBLICATION, EVIDENCE, and RESPONSE targets.
- DESIGN.md:1034-1036 and specs/database/addendum/global.yaml:121 require anti-resurrection.
- infra/scripts/restore.sh:48-57 restores and reports success without a post-backup suppression overlay.

Root cause:

Hold coverage is an object-type enum rather than a closed relation-row authority, while suppression state is stored inside the same historical database being restored.

Required acceptance evidence:

- A canonical relation registry and typed primary-key digest anchor for every legal_hold_key.
- Placement, release, and terminal action using the same advisory/row-lock authority.
- Restore states QUARANTINED, RECONCILING, ACTIVATABLE, and BLOCKED.
- A signed or WORM current suppression overlay with a monotonic high-watermark.
- Backup-before-deletion then restore-after-deletion tests proving no DB, object, index, cache, queue, or provider egress resurrection.

### TPL-R1-P0-005 — RecordClassSchedule and communication-consent contracts are not type-compatible

Evidence:

- specs/product/addendum-resource-error-contracts.yaml:386-388 uses schedule and consent vocabularies that differ from the database.
- specs/database/addendum/0028-governance-operations.yaml:639-729 requires different terminal, hold, restore, owner, derivative, and duration semantics.
- specs/database/addendum/0027-communication-consent-delivery.yaml:418,576 references undefined CommunicationTopicScopeV1 and PendingCommunicationAuthorizationBindingV1.
- specs/database/addendum/0027-communication-consent-delivery.yaml:605-625 allows only one source authorization while 2266-2270 requires multi-endpoint revocation.

Root cause:

Product payloads, database logical JSON types, state machines, and effects were designed independently.

Required acceptance evidence:

- One canonical schedule vocabulary across API, action payload, SQL, event, and UI.
- Destructive actions require duration; preserve actions require null duration.
- Legal-approved complete record-class bootstrap and production stale/missing preflight.
- Closed communication scope schemas, multi-revocation identity, and an unsent/retry/fallback concurrency fence.

### TPL-R1-P0-006 — AssetRightsDecision wire, database, and authorization models describe different domains

Evidence:

- specs/product/addendum-resource-error-contracts.yaml:371-395 and specs/product/addendum-operation-contracts.yaml:105-108 use six coarse dimensions and ALLOW, RESTRICT, DENY, REVIEW_REQUIRED.
- specs/database/addendum/0025-evidence-snapshots-search.yaml:1268-1348 uses nine independent rights and GRANT, DENY, SUSPEND, REVOKE.
- specs/database/addendum/0025-evidence-snapshots-search.yaml:1307-1324 stores unreferenced approval and execution digests.
- specs/database/addendum/0026-agent-action-approval.yaml:586-600,780-792 contains the missing execution candidate keys.

Root cause:

The action payload was not derived from the canonical rights relation and its approval/execution graph.

Required acceptance evidence:

- One AssetRightsDecisionCommandV2 across wire, Rust, SQL, event, and UI.
- Exact asset identity, revision, hash, prior decision, nine rights, legal basis, attribution, policy, evidence, approval, execution, and terminal receipt bindings.
- Composite foreign keys and a function-only SERIALIZABLE mutation.
- Enum and field set-equality plus stale/mismatched/forged-digest PostgreSQL tests.

### TPL-R1-P0-007 — Rights and legal-hold decisions are not enforced on effect paths

Evidence:

- specs/application/command-semantics.yaml:7097-7137 checks only whether a source is enabled.
- specs/application/command-semantics.yaml:1958-2065 omits complete rights and hold checks for export and redaction.
- specs/database/addendum/0025-evidence-snapshots-search.yaml:866,892-915,970,992-1021 stores unverifiable rights digest values for provider turns and tool calls.
- specs/database/addendum/0025-evidence-snapshots-search.yaml:1805-1809 records missing direct SourceAsset and ResearchArtifact hold coverage.

Root cause:

Rights are metadata rather than a relational authorization input recomputed at enqueue and claim time.

Required acceptance evidence:

- An immutable rights-use binding graph for provider turns, tools, excerpts, derivatives, exports, and publications.
- A shared direct and transitive hold resolver for SourceAsset, ResearchArtifact, and DatasetSnapshot.
- Enqueue and claim-time fences.
- Missing, UNKNOWN, DENY, expired, suspended, revoked, or DISCLOSURE hold produces zero external effect.

### TPL-R1-P0-008 — The canonical PublicationGate is bypassed and cannot bind every source kind

Evidence:

- specs/application/command-semantics.yaml:5029-5089 and services/control-api/src/service/mod.rs:2281-2388 insert publication revisions directly.
- specs/database/addendum/0028-governance-operations.yaml:1096-1187,1530-1548 defines a separate gate and intended owner procedure.
- specs/database/addendum/0028-governance-operations.yaml:1620-1627 marks the contradiction blocking.
- specs/database/addendum/0028-governance-operations.yaml:1206-1244 allows RESPONSE_SUBMISSION and EDITORIAL_RECORD while the rights relation supports only SOURCE_DOCUMENT and RESEARCH_ARTIFACT.

Root cause:

The gate was added as parallel design documentation instead of replacing the runtime mutation authority and defining a source-kind discriminated binding.

Required acceptance evidence:

- All publication, correction, and retraction through one SERIALIZABLE owner procedure.
- Every new revision has one non-null PASS gate reference.
- PASS means revision 1 and blockers 0; BLOCKED means revision 0 and blockers at least 1.
- RAW_SOURCE_DOCUMENT, RESPONSE_SUBMISSION, and EDITORIAL_RECORD variants require their exact rights, consent/excerpt, or policy decision.
- Direct runtime inserts fail.

### TPL-R1-P0-009 — PublicationGate does not fail closed on corroboration, copy safety, entity identity, counter-evidence, or AI provenance

Evidence:

- specs/database/addendum/0028-governance-operations.yaml:1189-1237 lacks source-family and exact rendered-copy bindings.
- specs/database/addendum/0028-governance-operations.yaml:1332-1337 omits the required blocker vocabulary.
- specs/api/resource-schemas.yaml:7306-7338 reduces language safety to a generic boolean.

Root cause:

Editorial safety remains an advisory UI field instead of material gate evidence bound to the exact public output.

Required acceptance evidence:

- Blockers CORROBORATION_INSUFFICIENT, COPY_SAFETY_UNSATISFIED, ENTITY_RESOLUTION_UNVERIFIED, COUNTER_EVIDENCE_UNADDRESSED, and AI_PROVENANCE_INCOMPLETE.
- One official outcome or two independent source families; republished URLs from one origin remain one family.
- Title, body, quote, caption, alt text, snippet, and notification bind to the same versioned copy-safety evaluation.
- Public claims expose a closed epistemic class, origin, human-review state, methodology link, and non-probabilistic uncertainty wording.

### TPL-R1-P0-010 — ResearchArtifact promotion, response excerpt, and dataset release lack immutable provenance

Evidence:

- specs/database/addendum/0025-evidence-snapshots-search.yaml:1760-1764 has no human ResearchArtifact-to-Evidence promotion command or receipt.
- specs/database/addendum/0025-evidence-snapshots-search.yaml:1780-1804 lacks response content and selected-segment lineage.
- specs/api/resource-schemas.yaml:6373-6404 declares publication consent, but specs/application/command-semantics.yaml:581-621 and services/control-api/src/service/mod.rs:1845-1873 mutate an excerpt without complete consent/version enforcement.
- specs/api/resource-schemas.yaml:6127-6159, specs/api/operation-contracts.yaml:4079-4151, and services/workflow-worker/src/runner.rs:484-564 do not bind dataset exports to an immutable snapshot, rights, hold, license, or downloadable status session.

Root cause:

Derived evidence and exports reuse mutable rows rather than producing immutable, rights-bound promotion and release objects.

Required acceptance evidence:

- EVIDENCE_PROMOTION action, private executor, immutable promotion receipt, and Evidence composite provenance.
- Immutable ResponseExcerptDecision bound to exact bytes/ranges, response/consent versions, redaction, identity mode, attachment rights, hold, reviewer, and policy.
- PublicDatasetRelease and DatasetRightsManifest with snapshot/member/license/attribution/hold/gate digests.
- One-time exchange, scoped status, and same-origin or short-lived signed download flow.

### TPL-R1-P0-011 — External correction, internal editorial work, correction publication, and retraction are disconnected

Evidence:

- db/migrations/0003_editorial_and_intake.sql:195-209,278-293 defines unrelated intake and editorial correction tables.
- specs/application/command-semantics.yaml:1765-1826 inserts intake and notification only.
- specs/events/event-catalog.yaml:246-255 and specs/events/consumer-catalog.yaml:55-65 provide no materializer consumer.
- specs/application/command-semantics.yaml:1601-1645 and services/control-api/src/service/mod.rs:1610-1647 create only a draft.
- services/control-api/src/service/mod.rs:2619-2658 marks the correction published without a new publication revision.
- specs/product/addendum-operation-contracts.yaml:85-88 names PublishRetraction without a complete command, persistence, event, or runtime path.
- services/projection-worker/src/runner.rs:189-205,268-283 updates historical revision payloads.

Root cause:

Intake, editorial review, publication, projection, requester receipt, and notification were implemented as separate local workflows rather than one receipt-bound state graph.

Required acceptance evidence:

- Exactly one internal work item materialized from one external request.
- NORMAL, CORRECTION, and RETRACTION_TOMBSTONE publication content variants.
- Approved correction/retraction atomically creates a new immutable revision, gate, notice, latest pointer, audit, outbox, and receipt.
- RESOLVED requires a concrete effect receipt.
- Projector replay is no-op only for equal digest; historical UPDATE count remains zero.
- Requester and correctly scoped subscribers receive post-projection notifications.

### TPL-R1-P0-012 — Appeal session, independence, withdrawal, remedy, and visible actions are incomplete

Evidence:

- specs/product/addendum-operation-contracts.yaml:290-311 uses the generic response receipt session.
- specs/database/addendum/0027-communication-consent-delivery.yaml:81-84,2271-2275,2398-2406 conflicts between appeal-specific and response-receipt scopes.
- specs/product/addendum-state-machines.yaml:116-122 and specs/product/addendum-operation-contracts.yaml:455-466 permit staff withdrawal without a requester command.
- specs/database/addendum/0027-communication-consent-delivery.yaml:2024-2062 resolves against a generic evidence UUID rather than an outcome-specific effect.
- specs/ui/screen-catalog.yaml:5478-5513 has no complete RSP-006 create, attach, submit, status, and withdraw action flow.

Root cause:

Appeal operations were attached to the response receipt surface without a distinct authorization and remedy lifecycle.

Required acceptance evidence:

- APPEAL_CREATE and APPEAL_STATUS sessions and safe rotation.
- Requester-only withdrawal.
- Prior-decider exclusion, independent assignment, conflict snapshot, and recusal.
- Typed effect receipt for REOPEN_RESPONSE, REVIEW_EXCERPT, CORRECT_STATUS, EXTEND_DEADLINE, and HUMAN_REVIEW.
- RSP-006 SSR, keyboard, mobile, expiry, retry, and status-re-entry E2E.

### TPL-R1-P0-013 — ConflictDeclaration, recusal, and approval binding are not decision-complete

Evidence:

- specs/database/addendum/0028-governance-operations.yaml:316-388,1573-1577 has relations and events but no complete declaration command/query surface.
- specs/product/addendum-resource-error-contracts.yaml:451-458 permits nullable conflictDeclarationId for RECUSE.
- specs/database/addendum/0028-governance-operations.yaml:80-103,323-378,433-458 has precedence but no total disposition matrix and collapses independent source authorities into one series.
- specs/product/addendum-approval-policy.yaml:19-23 and specs/database/addendum/0026-agent-action-approval.yaml:31-37 require one binding digest, while specs/product/addendum-resource-error-contracts.yaml:407-444 includes decisionKind.

Root cause:

Conflict facts, disposition, assignment replacement, and decision receipts do not share one canonical binding model.

Required acceptance evidence:

- record/list conflict declarations and get conflict snapshot.
- Source-authority-specific append-only series and multi-declaration set digest.
- A total conflict-disposition policy over effect, action, role, relationship, materiality, and time.
- RECUSE requires a declaration and atomically creates exactly one replacement assignment.
- ApprovalBinding excludes decisionKind; decision actor/kind/reason/assurance belongs to the immutable decision receipt.

### TPL-R1-P0-014 — Funding disclosure, conditional quorum, denominator, actor independence, and public projection are incomplete

Evidence:

- specs/product/addendum-operation-contracts.yaml:113-116 exposes a single amount/concentration payload.
- specs/product/addendum-resource-error-contracts.yaml:311-317 and specs/database/addendum/0026-agent-action-approval.yaml:195-198 disagree on target vocabulary.
- specs/product/addendum-approval-policy.yaml:109-113 defines two slots while specs/database/addendum/0029-funding-disclosure.yaml:562-577 requires oversight or board participants.
- specs/database/addendum/0026-agent-action-approval.yaml:609 caps counted decisions at three.
- specs/database/addendum/0029-funding-disclosure.yaml:50-70 stores an opaque denominator digest and 475-495 binds one conflict snapshot for several actors.
- specs/database/addendum/0029-funding-disclosure.yaml:843-848 records the public projection as unresolved.

Root cause:

Funding approval was modeled as a generic action payload rather than a snapshot, denominator, revision, conditional-quorum, and per-actor independence graph.

Required acceptance evidence:

- Snapshot-bound target with fiscal period, as-of/effective time, denominator, grouping, UNKNOWN and dispute reasons, ordered entries, thresholds, source/evidence, and policy/conflict/public-content digests.
- Denominator authority object and approval receipt.
- STANDARD, OVERSIGHT, BOARD, and related-case quorum classes with 1..16 counted decisions.
- Per-role actor conflict bindings and pairwise independence.
- Boundary tests at 5, 15, and 25 percent and every denominator UNKNOWN cause.
- FundingDisclosurePublicV1 current revision, history, caveat, sources, and report metadata rendered by PUB-023.

### TPL-R1-P0-015 — AI tools, entity resolution, suggestion acceptance, and public AI explanation are not typed

Evidence:

- specs/agents/schemas/source-fetch.request.schema.json:3-30, entity-lookup.response.schema.json:3-56, and claim-language_check.response.schema.json:3-56 are generic and materially identical.
- specs/database/addendum/0025-evidence-snapshots-search.yaml:870-875,967-976,1149-1150 references undefined v2 logical JSON types.
- scripts/validation/agents.py:7-21 validates files and keywords rather than semantic schema differences.
- tests/acceptance/entity-resolution.feature:20-31 requires human merge and revert, but specs/product/owner-addendum-2026-07-14.yaml:285-303 has no entity-resolution action kind.
- specs/application/command-semantics.yaml:7-48 accepts a suggestion without atomically materializing exactly one typed target.

Root cause:

The agent layer uses one search-shaped envelope and free-form output where the product needs tool-specific provenance, abstention, human identity decisions, and target-bound proposal receipts.

Required acceptance evidence:

- Tool-specific closed request/response schemas and resolution of every referenced logical JSON type.
- AgentRunViewV2 with snapshot, prompt/schema/model/tool receipts, exact citation revision/hash/locator, findings, contrary evidence, unknowns, abstention, and typed proposals.
- Human MERGE, KEEP_DISTINCT, and REVERT lifecycle with correction-impact receipt.
- ACCEPT atomically creates exactly one materialized target; REJECT creates zero.
- Stale, superseded, expired, citation-invalid, rights-blocked, and budget-blocked states.

### TPL-R1-P0-016 — Screen closure and acceptance mapping do not prove the above capabilities are reachable

Evidence:

- scripts/generate_design_screen_closure.py:143-167,398-423 uses keyword and round-robin fallback selection.
- scripts/validation/design.py:751-772,844-854 checks non-empty or generated text properties rather than semantic field requirements.
- New privacy, rights, conflict, funding, approval, appeal, and AI operations are commonly section labels without visible action, state-dependent availability, request binding, receipt focus, or success destination.

Root cause:

Generated screen closure is being treated as semantic proof even though it does not derive a screen's required answer, evidence, uncertainty, action, and consequence fields from typed operation schemas.

Required acceptance evidence:

- Explicit typed slices for all 94 screens and 496 sections.
- Operation response leaf and type resolution plus required-field set equality.
- Every user-callable command has a visible action, section, request-field source, state-dependent enable/disable reason, consequence, step-up path, receipt, and destination.
- Missing, zero, skipped, focused, fixture-only, placeholder, or 501 paths hard fail.

## P1 findings

### TPL-R1-P1-001 — Privacy notice acknowledgment is confused with legal processing basis

Evidence: specs/product/addendum-resource-error-contracts.yaml:255,260 and specs/product/addendum-operation-contracts.yaml:571-574 require privacyConsent true.

Required change: versioned notice acknowledgment and counsel-approved processing basis must be separate; declining optional contact consent cannot block exercise of a right.

### TPL-R1-P1-002 — Publication consent loses identity and excerpt-review semantics

Evidence: specs/api/resource-schemas.yaml:6373-6435 contains detailed consent but downstream publication models and gates do not preserve all fields.

Required change: immutable consent revision, withdrawal, exact excerpt preview, identity-display mode, attachment decisions, and immediate gate staleness.

### TPL-R1-P1-003 — Public provenance omits segment, rights, license, and attribution

Evidence: specs/product/owner-addendum-2026-07-14.yaml:684-705 and specs/database/addendum/0025-evidence-snapshots-search.yaml:503-526.

Required change: evidence segment ID/digest, selected-content digest, parser/transformation provenance, public-safe reuse class, license policy/digest, attribution, and an internal exact rights-decision pointer.

### TPL-R1-P1-004 — Retraction quorum is contradictory

Evidence: DESIGN.md:680 and specs/product/addendum-approval-policy.yaml:77-81.

Required change: one risk-derived quorum with editor and publisher plus legal for high risk, encoded identically in policy, database, UI, and tests.

### TPL-R1-P1-005 — Legal-hold release lacks a usable review surface

Evidence: specs/product/addendum-operation-contracts.yaml:278-289,609 and specs/ui/screens/REV-002.md:49-67.

Required change: cell-level active/released coverage, partial-release preview, exact consequence, confirmation, and visible query/action binding.

### TPL-R1-P1-006 — Funding, conflict, and publication events are not reconstructive

Evidence: specs/product/addendum-event-contracts.yaml:86,109-111 and specs/database/addendum/0028-governance-operations.yaml:1103-1145.

Required change: complete material-field payloads or a strict pointer-only event whose consumers resolve and verify decision ID plus digest. DB outcome and event vocabulary must be identical.

### TPL-R1-P1-007 — Correction requester status and notification scope are not durable

Evidence: db/migrations/0024_v13_submission_session_boundary.sql:378-380,437; services/submission-api/src/service/correction.rs:176-264; services/notification-worker/src/runner.rs:355-414,602-613.

Required change: verified long-term re-entry, requester-safe state/decision/revision/notice fields, verified requester endpoint, exact subscription scope, and post-projection notification.

### TPL-R1-P1-008 — Trust and uncertainty UX lacks representative hard gates

Evidence: the critical-task list does not cover PUB-013, PUB-023, PUB-024, or PUB-025, and generated special states do not carry typed trigger, precedence, preservation, action, focus, or live-region contracts.

Required change: TRUST-FUNDING, TRUST-GOVERNANCE, AI-UNCERTAINTY, and APPROVAL-CONFLICT tasks using real PostgreSQL through API, SSR, and browser at compact/wide, keyboard, screen reader, 200 percent, and 400 percent.

## P2 findings

### TPL-R1-P2-001 — Trust information is discoverable mainly through the public footer

Evidence: specs/ui/navigation.yaml:13-32,44-49.

Required change: add a plain-language Transparency entry to header and compact navigation, and link case-level trust disclosures to the exact funding and editorial-policy revisions within two actions.

### TPL-R1-P2-002 — Internal vocabulary leaks into public copy

Evidence: specs/ui/screen-catalog.yaml:3132-3183 and specs/ui/state-profile-contracts.yaml:35-40,188-193,238-243.

Required change: Korean-first terminology and per-screen state copy that says what is visible, what is missing, the as-of time, preserved data, and the next safe action.

### TPL-R1-P2-003 — COR-002 defaults to rejection

Evidence: specs/ui/screens/COR-002.md:54-59.

Required change: while evidence is incomplete, continue verification or save draft is primary. Correction, retraction, and no-change become a neutral decision group only at a decision-ready state.

## Minimum independent re-review gate

Independent re-review may start only after every P0 has:

1. A canonical policy or type definition.
2. A closed state machine and error vocabulary.
3. An immutable persistence and composite-FK graph.
4. A single mutation or execution owner.
5. A reconstructive event and durable receipt.
6. A visible screen action and typed view model.
7. PostgreSQL, Rust, SSR, browser, accessibility, concurrency, retry, and negative acceptance evidence appropriate to the effect.

Required end-to-end proofs include:

- All four privacy rights and restore-after-deletion reconciliation.
- Rights decision through provider/tool/export/publication fences.
- PASS gate to exactly one immutable revision and BLOCKED gate to zero revisions.
- External correction through immutable correction or retraction notice and scoped notification.
- Response consent through excerpt decision, appeal, and concrete remedy.
- Dataset release through status and download with mid-flight revocation.
- Funding threshold, quorum, denominator, independence, public history, and stale caveat.
- Agent tool provenance, entity decision, exact-target acceptance, and human-readable uncertainty.
- Missing, skip, focused, fixture-only, placeholder, and 501 scans that fail closed.

No LGTM is supported by the reviewed state.
