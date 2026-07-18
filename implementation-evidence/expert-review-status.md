# Expert Review Status

This matrix is the implementation release gate. A verdict applies only to the exact
commit and worktree digest it reviewed. Any substantive change in a role's scope
makes that role `STALE` until independent re-review. Design gates are tracked
separately below and never substitute for implementation evidence.

Allowed states: `REVIEW_IN_PROGRESS`, `CHANGES_REQUIRED`, `LGTM`, `STALE`.
The exact fourteen canonical role IDs and historical aliases come from
`implementation-evidence/expert-review-roles.yaml`; this matrix is a status
projection and cannot add, remove or rename a role.

| Gate | Current state | Reviewed baseline | Blocking summary |
|---|---|---|---|
| PDM | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Generic journeys, missing typed outcomes, no measurable activation/retention loop |
| PRODUCT_DESIGN | CHANGES_REQUIRED | `0f7c7be` + dirty tree | 94 generic pages, missing components/states, raw operation/JSON UX |
| BUSINESS_MODEL | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Payer/value loop not delivered, analytics absent, funding/governance stubs |
| AI_MULTIMODAL_RESEARCH | CHANGES_REQUIRED | `0f7c7be` + dirty tree | No real tool loop/content, schema mismatch, no dataset-snapshot execution |
| DATA_VISUALIZATION | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Search/list inputs ignored, synthetic fields, no provenance visualization |
| DATABASE | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Additive migrations, repositories, constraints and concurrency proofs absent |
| COMMAND_EVENT_LIFECYCLE | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Additive command/event/persistence/runtime lifecycle is not wired |
| HUMAN_APPROVAL | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Exact decision binding, independence, fencing, and receipt are incomplete |
| OMNICHANNEL_SESSION | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Email-only path; consent, adapter, provider receipt, reconciliation absent |
| ACCESSIBILITY_RESPONSIVE | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Generic/raw UI and mock/unauthenticated visuals do not prove task completion |
| TRUST_PRIVACY_LEGAL | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Publication gate bypasses, response/correction lifecycle gaps, consent/rights gaps |
| SRE_FINOPS | CHANGES_REQUIRED | `0f7c7be` + dirty tree | False-green status, unenforced budget/kill switch, pagination/restore/capacity gaps |
| QA_TRACEABILITY | CHANGES_REQUIRED | `0f7c7be` + dirty tree | 0/271 mapped scenarios executable; supplemental implementation/receipts absent |
| PROCUREMENT_DOMAIN | CHANGES_REQUIRED | `0f7c7be` + dirty tree | Procurement mapping, identity, temporal and comparability runtime gaps remain |

## Update protocol

1. Record each finding with a stable role-prefixed ID in a review report.
2. Main implementation owner fixes the root cause and produces focused evidence.
3. A separate reviewer retests all prior IDs and checks for regressions.
4. `LGTM` is entered only when the response follows
   `implementation-evidence/expert-review-prompt.md` and has no P0/P1.
5. After any relevant source, schema, migration, test-contract, UX, or deployment
   change, mark affected `LGTM` entries `STALE` before relying on them.
6. Release requires fourteen simultaneous, current `LGTM` entries for the same clean
   source-tree commit and final evidence bundle.

## Design review status

The design bundle is the sorted SHA-256 manifest of `DESIGN.md`,
`implementation-evidence/spec-conflicts.md`,
`implementation-evidence/expert-review-prompt.md`,
`implementation-evidence/design-screen-closure.yaml`,
`implementation-evidence/design-domain-closure.yaml`, and
`specs/product/owner-addendum-2026-07-14.yaml`.

| Design gate | Current state | Bundle | Note |
|---|---|---|---|
| PDM | STALE | `bd5a31d9…` LGTM | Bundle changed after PDM-DES-001..005 closed |
| PRODUCT_DESIGN | STALE | `bd5a31d9…` CHANGES_REQUIRED | PD-DESIGN-001..006 require route, screen, state, responsive and test closure |
| ACCESSIBILITY_RESPONSIVE | STALE | `bd5a31d9…` CHANGES_REQUIRED | CA-DESIGN-001..002 require semantic screen closure and reproducible usability protocol |
| BUSINESS_MODEL | STALE | `bd5a31d9…` CHANGES_REQUIRED | BM-R2-001..003 require fact, tariff and first-SKU readiness contracts |
| AI_MULTIMODAL_RESEARCH | STALE | `bd5a31d9…` CHANGES_REQUIRED | ADP-R2-001..003 require exact schemas, snapshot production and executable oracles |
| DATA_VISUALIZATION | STALE | `bd5a31d9…` CHANGES_REQUIRED | SV-DES-001..003 patched in a later bundle; independent retest pending |
| DATABASE | STALE | `bd5a31d9…` CHANGES_REQUIRED | Physical relation, migration, authorization and concurrency design retest pending |
| COMMAND_EVENT_LIFECYCLE | STALE | `bd5a31d9…` CHANGES_REQUIRED | Command, event, persistence and terminal/recovery design retest pending |
| HUMAN_APPROVAL | STALE | `bd5a31d9…` CHANGES_REQUIRED | HAP-DG-R2-001..005 require exact operations, binding, quorum and execution transitions |
| OMNICHANNEL_SESSION | STALE | `bd5a31d9…` CHANGES_REQUIRED | OMNI-DG-001..005 require screen/API ownership, consent, transitions and adapter contracts |
| SRE_FINOPS | STALE | `bd5a31d9…` CHANGES_REQUIRED | DSRE-DESIGN-001..003/005..006 require exact SLI, lifecycle and economics contracts |
| TRUST_PRIVACY_LEGAL | STALE | `bd5a31d9…` CHANGES_REQUIRED | TRUST-DES-009..011 and prior trust findings require canonical mutation contracts |
| QA_TRACEABILITY | STALE | `bd5a31d9…` CHANGES_REQUIRED | ACCEPTANCE-P1-001..004 require supplemental runner and non-circular extraction contracts |
| PROCUREMENT_DOMAIN | STALE | `bd5a31d9…` CHANGES_REQUIRED | Procurement identity, source revision, temporal and comparability design retest pending |

A design bundle change marks all affected design verdicts `STALE`. An
implementation-only change does not invalidate a design verdict unless it exposes a
design contradiction. No implementation starts for an affected contract until its
design gate is `LGTM`.
