# CONTRACT_SPLITTING_PATTERN Independent Reference Oracle

Version: `1.0.0`

## Formula

same agency+supplier+category single-source contracts, each below threshold, within window; aggregate >= threshold

## Required input
- `contracts`
- `single_source_threshold`
- `window_days`

## Thresholds

```yaml
minimum_contracts: 3
aggregate_gte_threshold_multiplier: '1.0000'
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `INSUFFICIENT_CONTRACTS`
- `DATE_UNKNOWN`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- input order does not change result
- duplicate contract id ignored
- contracts outside window do not contribute

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/contract_splitting_pattern.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
