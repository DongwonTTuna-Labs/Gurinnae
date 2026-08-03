# YEAR_END_SPENDING_SPIKE Independent Reference Oracle

Version: `1.0.0`

## Formula

December spend / annual spend and December / median(Jan-Nov)

## Required input
- `monthly_spend`
- `monthly_contract_count`

## Thresholds

```yaml
december_share_gte: '0.2500'
december_to_prior_median_gte: '3.0000'
minimum_annual_contracts: 10
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `INCOMPLETE_YEAR`
- `INSUFFICIENT_CONTRACTS`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- contract ordering irrelevant
- all-zero prior months block ratio
- same annual total alone does not determine signal

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/year_end_spending_spike.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
