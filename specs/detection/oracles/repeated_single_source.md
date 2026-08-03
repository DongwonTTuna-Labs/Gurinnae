# REPEATED_SINGLE_SOURCE Independent Reference Oracle

Version: `1.0.0`

## Formula

count and sum same agency+supplier+category single-source contracts within window

## Required input
- `contracts`
- `window_days`

## Thresholds

```yaml
minimum_contracts: 4
minimum_distinct_days: 3
minimum_total_amount: 50000000
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `INSUFFICIENT_CONTRACTS`
- `DATE_UNKNOWN`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- input order does not change result
- competitive contracts excluded
- duplicate contract id ignored

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/repeated_single_source.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
