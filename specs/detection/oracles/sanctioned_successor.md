# SANCTIONED_SUCCESSOR Independent Reference Oracle

Version: `1.0.0`

## Safety boundary

This rule produces an anomaly-triage signal only. `publication_claim_allowed` is `false`.
It never merges suppliers, changes a case or publication state, scores a natural person, or
infers a family or kinship relationship.

Natural-person matching is limited to an exact lowercase SHA-256 person digest from an immutable
`MANAGEMENT_ROLE` assertion. The assertion must be `VERIFIED`, public-use `APPROVED`, independently
human-verified, validity-complete, evidence-bound, and sourced from DART, ALIO, the official gazette,
or a public-official ethics notice (`PUBLIC_OFFICIAL_ETHICS_NOTICE`). Names, addresses, birth dates,
family data, probabilities, ranks, and scores are never inputs to matching.

## Operational state

The PPS sanction report connector is registered `DISABLED`. Evaluation therefore returns
`BLOCKED/SANCTION_SOURCE_NOT_READY` until an operator confirms file access and reuse rights, a
credentialed preflight receipt and exact CSV schema fingerprint are pinned by a `READY` connector
activation receipt, and complete sanction effective dates plus supplier strong identifiers are
frozen in the dataset snapshot.

## Policy authority

There is no production default or active seed. Absence of the immutable policy is inactive and
returns `RULE_POLICY_INACTIVE`. Every policy must supply:

```yaml
maximum_new_entity_age_days: integer >= 0
post_sanction_award_window_days: integer >= 0
sanction_effective_date_semantics: START_DATE_INCLUSIVE | END_DATE_INCLUSIVE
link_match_mode: STRONG_IDENTIFIER_OR_APPROVED_OFFICER |
                 STRONG_IDENTIFIER_ONLY |
                 APPROVED_OFFICER_ONLY
```

The 30 oracle cases use this test-only policy unless a case explicitly changes it:

```yaml
maximum_new_entity_age_days: 365
post_sanction_award_window_days: 180
sanction_effective_date_semantics: START_DATE_INCLUSIVE
link_match_mode: STRONG_IDENTIFIER_OR_APPROVED_OFFICER
```

These values are fixture authority only and must not be inserted by a production migration.

## Formula

For every distinct sanctioned-supplier and award-supplier pair:

1. `successorAgeDays = awarded_at - incorporated_at` and must be within
   `[0, maximum_new_entity_age_days]`.
2. Select the sanction anchor from the policy:
   - `START_DATE_INCLUSIVE`: `effective_from`;
   - `END_DATE_INCLUSIVE`: `effective_to`.
3. `postSanctionDays = awarded_at - anchor` and must be within
   `[0, post_sanction_award_window_days]`.
4. At least one policy-enabled link must match:
   - same `(canonical scheme, value_hash)` where both facts are `VERIFIED + PROVEN_V1`; or
   - same exact person digest where the sanctioned-supplier role covers the sanction anchor and the
     successor-supplier role covers the award date, with the approved officer shape above.

A known complete match is sufficient under the OR policy even if the other channel is incomplete.
Without a match, every enabled channel must have complete coverage; otherwise evaluation is
`BLOCKED/LINK_EVIDENCE_INCOMPLETE` rather than `NO_SIGNAL`.

## Identifier admission

Only these canonical strong schemes are admitted:

- `KOREAN_BUSINESS_NUMBER`
- `OPEN_DART_CORP_CODE`
- `KONEPS_PARTY_KEY`

Legacy aliases (`BUSINESS_NUMBER`, `DART_CORP_CODE`), `LEGACY_UNPROVEN`, weak identifiers, names,
unverified facts, and malformed digests never match.

## Blockers

- `RULE_POLICY_INACTIVE`: immutable policy absent.
- `RULE_POLICY_INVALID`: a required policy field is absent, unsupported, or negative.
- `REQUIRED_FIELD_MISSING`: required materialized collection or record field absent.
- `SANCTION_SOURCE_NOT_READY`: sanction source status is not `READY`.
- `INSUFFICIENT_CONTEXT`: no sanction, fewer than two suppliers, or no award.
- `ENTITY_BINDING_MISMATCH`: duplicate supplier or sanction/award supplier missing from the snapshot.
- `TEMPORAL_COVERAGE_INCOMPLETE`: invalid chronology or required effective date unavailable.
- `LINK_EVIDENCE_INCOMPLETE`: a temporally eligible pair has no admitted link and at least one
  enabled link channel lacks complete coverage.

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, and
`result_hash`. SIGNAL includes the matched sanction, award, sanctioned supplier, and successor
supplier IDs. Excluded IDs are unmatched sanction and award evidence IDs.

Metrics are:

- `candidate_context_count`
- `matched_context_count`
- `shared_strong_identifier_count`
- `shared_approved_officer_count`
- `maximum_new_entity_age_days`
- `post_sanction_award_window_days`
- `sanction_effective_date_semantics`
- `link_match_mode`

## Oracle distribution

- 10 positive cases: canonical strong links, approved officer links, both link types, inclusive
  date boundaries, and both effective-date semantics.
- 15 false-positive controls: weak/legacy/unproven/unverified identifiers, same names without exact
  digest, pending/denied/non-independent/non-official officer assertions, validity mismatch, old
  entities, pre-sanction awards, and awards outside the configured window.
- 5 missing-data cases: inactive policy, disabled sanction source, an internally incomplete strong
  identifier fact, incomplete temporal coverage, and a malformed officer-role date. Both damaged
  link records must return `BLOCKED/LINK_EVIDENCE_INCOMPLETE`, never an evaluator scalar error.

## Metamorphic invariants

- Reordering any input collection does not change the result.
- Display names never change a result.
- Replacing one exact digest with another removes only that link.
- `LEGACY_UNPROVEN` and weak facts remain non-links even when their hash text matches.
- Human approval, public-use approval, and official-source gates cannot be bypassed by another field.

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates all 30 cases in
`specs/detection/evals/sanctioned_successor.jsonl`. Rust output must equal the full expected object
byte-for-byte after canonical JSON serialization.
