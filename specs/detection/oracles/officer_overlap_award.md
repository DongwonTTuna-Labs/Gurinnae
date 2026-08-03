# OFFICER_OVERLAP_AWARD Independent Reference Oracle

Version: `1.0.0`

## Formula

Group award-time officer assignments by `(agency_id, person_identifier_digest)`. A signal exists only when one exact SHA-256 person digest is valid at the award date for at least `policy.minimum_distinct_suppliers` different awarded suppliers of the same agency.

Names are display-only and never participate in identity matching. Natural-person scoring, fuzzy matching, family inference, and automatic identity merging are forbidden.

## Required input

- `policy.minimum_distinct_suppliers` (integer, at least 2; no default)
- `source_coverage.dart_officer_assignments_complete` (`true` is required)
- `source_coverage.award_records_complete` (`true` is required)
- `source_coverage.relationship_periods_complete` (`true` is required)
- `source_coverage.relationships_verified` (`true` is required)
- `source_coverage.public_use_approved` (`true` is required)
- `source_coverage.independent_human_verification_complete` (`true` is required)
- `awards[]`: `id`, `agency_id`, `supplier_id`, `awarded_on`
- `officer_assignments[]`: `id`, `person_identifier_digest`, `supplier_id`, `valid_from`, `valid_to`

The test fixture uses an explicit development-only policy value. There is no production policy seed.

Operational status is `ACTIVATABLE`, not automatically active, only when every source-coverage and graph-review gate above is true and an immutable policy is supplied. Missing policy or coverage remains fail-closed.

## Validity rule

Employment validity is the closed interval `[valid_from, valid_to]`. Every contributing award date must fall inside that interval. DART officer coverage, award coverage, relationship periods, and the VERIFIED + APPROVED + independently human-verified graph snapshot must all be complete. Otherwise the result is `BLOCKED`; the evaluator must not infer an interval or graph assertion.

## Blockers

- `REQUIRED_FIELD_MISSING`
- `INVALID_POLICY_THRESHOLD`
- `SOURCE_COVERAGE_INCOMPLETE`
- `RELATIONSHIP_GRAPH_NOT_APPROVED`
- `INSUFFICIENT_CONTEXT`
- `PERSON_IDENTITY_DIGEST_INVALID`
- `DATE_INVALID`
- `VALIDITY_INTERVAL_INVALID`
- `DUPLICATE_RECORD_ID`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

Signal metrics include the agency and exact person digest plus matched supplier and award counts. `publication_claim_allowed` is always `false`; the result is triage input only.

## Metamorphic invariants

- Award and assignment order is irrelevant.
- Identical display names with different digests never match.
- Awards outside the employment interval never contribute.
- Incomplete source or graph validity coverage cannot produce `SIGNAL` or `NO_SIGNAL`.

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/officer_overlap_award.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
