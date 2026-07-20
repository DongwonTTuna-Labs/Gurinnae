# SUPPLIER_CONCENTRATION Independent Reference Oracle

Version: `1.0.0`

## Formula

top supplier spend / total comparable agency-category spend

## Required input
- `contracts`
- `minimum_total_spend`

## Thresholds

```yaml
supplier_share_gte: '0.6000'
minimum_supplier_contracts: 3
minimum_total_spend: 100000000
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `INSUFFICIENT_TOTAL_SPEND`
- `IDENTITY_AMBIGUOUS`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- input order does not change result
- duplicate contract id ignored
- unresolved supplier identity blocks

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/supplier_concentration.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
