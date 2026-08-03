# REVOLVING_DOOR_CONTRACT Independent Reference Oracle

Version: `1.0.0`

## Operational state

The rule is registered but operationally `BLOCKED`. No production default or active
policy seed exists. It may be unblocked only after an official Public Service Ethics
Committee notice or official-gazette connector supplies normalized, source-located
reemployment records with complete departure dates and independent human review as
`VERIFIED + APPROVED` `FORMER_OFFICIAL_ROLE` assertions.

The 30 evaluation records are synthetic structural fixtures. Their policy values and
`official_reemployment_source_available=true` flags are test authority only; they do
not activate production behavior or claim that an operational source exists.

## Required policy

All policy fields are required in the frozen snapshot input:

```yaml
cooling_period_days: positive integer
procurement_method_allowlist: non-empty exact uppercase token set
cooling_boundary: DEPARTURE_EXCLUSIVE_COOLING_END_INCLUSIVE
```

There are no defaults. Procurement methods use exact, case-sensitive membership;
wildcards and inferred aliases are forbidden. The date boundary is exactly:

```text
departed_on < contract.signed_on <= departed_on + cooling_period_days
```

## Authoritative join

A contract enters the signal cohort only when every condition holds:

1. A `FORMER_OFFICIAL_ROLE` joins `PERSON -> AGENCY` with a lowercase 64-hex exact
   person identifier digest.
2. That assertion has complete temporal coverage, evidence and source locator,
   independent human verification, `verification_status=VERIFIED`, and
   `public_use_status=APPROVED`.
3. Its source kind is `PUBLIC_OFFICIAL_ETHICS_NOTICE` or `OFFICIAL_GAZETTE`.
4. A DART `MANAGEMENT_ROLE` joins the same exact PERSON digest to the awarded
   supplier. It is likewise complete, independently reviewed, `VERIFIED`, and
   `APPROVED`, and its tenure covers the contract date. `valid_to=null` means the
   source authoritatively reports the role as ongoing through the frozen snapshot
   cutoff and is accepted only with `validity_coverage_status=COMPLETE`.
5. The contract agency exactly equals the former role's original agency, and the
   contract supplier exactly equals the DART officer role's supplier.
6. The contract's procurement method is an exact member of the supplied policy
   allowlist and its signed date lies inside the exclusive/inclusive cooling window.

Name similarity is not an identity join. No name, address, birth date, family or
kinship inference, personal score, rank, or probability participates in evaluation.

## Blockers

- `REQUIRED_FIELD_MISSING`: a required policy, coverage, relationship, or contract
  field is absent.
- `INVALID_FIELD_SHAPE`: a required value has the wrong JSON type or is empty.
- `POLICY_CONFIGURATION_INVALID`: a cooling period or exact allowlist/boundary is
  missing its required semantics.
- `OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE`: no approved official reemployment
  source is available. This is the current operational blocker.
- `OFFICIAL_REEMPLOYMENT_COVERAGE_INCOMPLETE`: the official-source coverage window is
  not complete.
- `OFFICER_SOURCE_NOT_AUTHORITATIVE`: the supplier officer fact is not from the DART
  executive-status source.
- `RELATIONSHIP_SHAPE_INVALID`: endpoint or relationship kinds do not match the typed
  graph contract.
- `RELATIONSHIP_REVIEW_INCOMPLETE`: independent human `VERIFIED + APPROVED` review is
  absent.
- `TEMPORAL_COVERAGE_INCOMPLETE`: a required date is absent/invalid or a relationship
  is not marked complete.
- `PERSON_IDENTITY_AMBIGUOUS`: a PERSON identifier is not an exact lowercase SHA-256
  digest.
- `DUPLICATE_CONTRACT_ID`: one frozen input contains conflicting duplicate contract
  identities.

Alternative explanations with complete authoritative data produce `NO_SIGNAL`, not a
signal: different exact person digest, different original agency, supplier mismatch,
contract outside the cooling window, non-allowlisted method, or officer tenure outside
the contract date.

## Exact output

The evaluator returns `outcome`, `blockers`, policy and match-only `metrics`, sorted
`included_ids`, sorted `excluded_ids`, `input_hash`, and `result_hash`. Metrics contain
only digests and relationship/contract identifiers; there is no natural-person score.
`publication_claim_allowed` remains `false`, and the rule cannot publish or activate a
relationship.

## Evaluation distribution

- 10 positive cases, including first-day and inclusive cooling-end boundaries.
- 15 false-positive controls covering digest, agency, supplier, method, tenure, and
  cooling-window separations; an unauthoritative person token is `BLOCKED` rather
  than treated as either an identity match or a negative identity decision.
- 5 missing-data/source/policy cases that must fail closed as `BLOCKED`.

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in
`specs/detection/evals/revolving_door_contract.jsonl`. Rust output must equal the full
expected object byte-for-byte after canonical JSON serialization.
