# PRICE_OUTLIER Independent Reference Oracle

Version: `1.0.0`

## Formula

ratio = target.unit_price / median(compatible comparable.unit_price)

## Required input
- `target.id`
- `target.unit_price`
- `target.unit`
- `target.category`
- `target.vat_included`
- `target.bundle_known`
- `target.observed_at`
- `comparables`

## Thresholds

```yaml
minimum_comparables: 8
ratio_gte: '3.0000'
date_window_days: 365
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `INSUFFICIENT_COMPARABLES`
- `TARGET_BUNDLE_UNKNOWN`
- `TARGET_VAT_UNKNOWN`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- input order does not change result
- duplicate source_key does not change cohort
- incompatible unit never enters cohort

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/price_outlier.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
