# LOW_BID_COMPETITION Independent Reference Oracle

Version: `1.0.0`

## Formula

competitive procurement with <=1 valid bidder and amount >= threshold, unless emergency

## Required input
- `procurement.id`
- `procurement.method`
- `procurement.valid_bidder_count`
- `procurement.estimated_amount`
- `procurement.emergency`

## Thresholds

```yaml
valid_bidder_count_lte: 1
minimum_estimated_amount: 50000000
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `METHOD_UNKNOWN`
- `BIDDER_COUNT_UNKNOWN`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- bidder order irrelevant
- noncompetitive method does not signal
- emergency suppresses

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/low_bid_competition.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
