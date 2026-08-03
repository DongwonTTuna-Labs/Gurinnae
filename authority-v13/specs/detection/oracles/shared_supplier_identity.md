# SHARED_SUPPLIER_IDENTITY Independent Reference Oracle

Version: `1.0.0`

## Formula

two distinct suppliers share >=2 strong identifier hashes and contract with same agency

## Required input
- `suppliers`
- `contracts`

## Thresholds

```yaml
minimum_shared_strong_identifiers: 2
minimum_combined_contracts: 3
minimum_combined_amount: 50000000
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `IDENTITY_HASH_MISSING`
- `INSUFFICIENT_CONTRACT_CONTEXT`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- supplier order irrelevant
- display values never used
- one weak shared identifier is insufficient

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/shared_supplier_identity.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
