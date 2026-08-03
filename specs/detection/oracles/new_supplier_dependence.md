# NEW_SUPPLIER_DEPENDENCE Independent Reference Oracle

Version: `1.0.0`

## Formula

young supplier and agency_spend / total_public_spend >= threshold

## Required input
- `supplier.id`
- `supplier.age_days`
- `supplier.agency_contract_count`
- `supplier.agency_spend`
- `supplier.total_public_spend`
- `supplier.identity_verified`

## Thresholds

```yaml
maximum_age_days: 365
minimum_contracts: 3
agency_share_gte: '0.5000'
minimum_agency_spend: 50000000
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `IDENTITY_AMBIGUOUS`
- `TOTAL_SPEND_ZERO`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- contract order irrelevant
- older supplier does not signal
- identity ambiguity blocks

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/new_supplier_dependence.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
