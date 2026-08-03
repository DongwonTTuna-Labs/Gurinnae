# RESTRICTIVE_SPECIFICATION Independent Reference Oracle

Version: `1.0.0`

## Formula

brand/model-specific requirement + no equivalent + <=1 valid bidder + no documented justification

## Required input
- `specification.id`
- `specification.brand_mentions`
- `specification.model_mentions`
- `specification.equivalent_allowed`
- `specification.valid_bidder_count`
- `specification.justification_present`

## Thresholds

```yaml
minimum_brand_or_model_mentions: 1
valid_bidder_count_lte: 1
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `SPECIFICATION_TEXT_UNAVAILABLE`
- `BIDDER_COUNT_UNKNOWN`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- text order irrelevant
- equivalent allowed suppresses
- documented justification suppresses

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/restrictive_specification.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
