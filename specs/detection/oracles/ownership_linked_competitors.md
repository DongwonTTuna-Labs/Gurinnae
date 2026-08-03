# OWNERSHIP_LINKED_COMPETITORS Independent Reference Oracle

Version: `1.0.0`

## Operational state

`BLOCKED` under deferred source `koneps-structured-bidder-participation` until an official KONEPS
operation provides structured participant rows for each procurement, including stable supplier
identity, bid amount, status, withdrawal and rank semantics, and the
connector, normalization, and frozen `DETECTION_DATASET` materializer prove complete row
coverage and emit `status: STRUCTURED_COMPLETE`. The current opaque participant string is not
an authorized substitute. Positive oracle inputs identify their source authority as
`TEST_FIXTURE_ONLY`; this is never an operational source declaration.

Source authority, status, and coverage are validated immediately after the procurement object.
If the source is unavailable, evaluation returns `STRUCTURED_BIDDER_SOURCE_UNAVAILABLE` before
requiring `bid_opened_at` or participant rows. A missing timestamp must never be fabricated to
reach the honest operational blocker; missing-data case 01 fixes this precedence contract.

## Formula

Within one procurement, select distinct participant rows whose `participation_status` is
`VALID` and whose `identity_status` is `VERIFIED`. At `bid_opened_at`, find the lexicographically
first pair joined by the shortest path of at most `policy.maximum_relationship_hops` edges.
Every counted edge must:

- be `OWNERSHIP` or `CONTROL`;
- have `verification_status: VERIFIED` and `public_use_status: APPROVED`;
- have both endpoint identities `VERIFIED`;
- declare complete period coverage; and
- have an inclusive `[valid_from, valid_to]` containing `bid_opened_at`.

`policy.minimum_linked_participants` is immutable and must equal `2` for rule version `1.0.0`.
`policy.maximum_relationship_hops` is required and must be `1` or `2`. No default or production
seed exists. Oracle cases use a test-fixture-only policy of `2` participants and `2` hops.

## Required input

- `policy.minimum_linked_participants`
- `policy.maximum_relationship_hops`
- `procurement.id`
- `procurement.bid_opened_at`
- `procurement.structured_participant_source.authority`
- `procurement.structured_participant_source.status`
- `procurement.structured_participant_source.coverage_complete`
- `procurement.participants[].{supplier_id, participation_status, identity_status}`
- `relationship_coverage_complete`
- `relationships[]`
- for each candidate ownership/control edge: `id`, supplier endpoints, verification/public-use
  states, endpoint identity states, validity dates, and `period_coverage_complete`

## BLOCKED versus NO_SIGNAL

Missing policy, source, coverage, identity, path fields, or validity-period facts is
`BLOCKED`: the evaluator cannot safely distinguish absence from incomplete evidence. An explicit
unapproved or unverified edge, an explicit non-overlapping period, a path longer than policy, or
an unrelated relationship is complete negative evidence and yields `NO_SIGNAL` when no other
qualifying path exists. Unknown participant or relationship vocabulary is also `BLOCKED`; family
or kinship is deliberately absent rather than treated as a usable relationship.

## Legal boundary

This rule uses supplier connectivity only. It neither creates identity decisions nor performs
automatic merges. Family and kinship relations are not part of the vocabulary and can never
contribute. The output is anomaly triage only and `publication_claim_allowed` is always `false`.

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, and
`result_hash`. Signal metrics record the procurement, valid-participant count, selected supplier
pair, path length, and relationship assertion IDs. Ordering changes must not change the selected
pair or path.

## Oracle corpus

`specs/detection/evals/ownership_linked_competitors.jsonl` contains exactly 30 concrete cases:
10 positive paths, 15 false-positive guards, and 5 missing-data/BLOCKED cases. Rust output must
equal the full expected object produced by the independent reference evaluator.
