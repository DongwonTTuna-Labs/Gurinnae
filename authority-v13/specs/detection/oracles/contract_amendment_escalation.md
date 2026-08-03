# CONTRACT_AMENDMENT_ESCALATION Independent Reference Oracle

Version: `1.0.0`

## Formula

final_amount / original_amount >= threshold and amendment_count >= minimum

## Required input
- `contract.id`
- `contract.original_amount`
- `contract.final_amount`
- `contract.amendment_count`
- `contract.scope_change_explained`

## Thresholds

```yaml
final_to_original_ratio_gte: '1.5000'
minimum_amendments: 2
minimum_original_amount: 10000000
```

## Blockers
- `REQUIRED_FIELD_MISSING`
- `ORIGINAL_AMOUNT_ZERO`
- `AMENDMENT_HISTORY_INCOMPLETE`

## Exact output

`outcome`, `blockers`, `metrics`, sorted `included_ids`, sorted `excluded_ids`, `input_hash`, `result_hash`.

## Metamorphic invariants
- amendment order irrelevant
- explained scope suppresses
- currency mismatch blocks

## Executable authority

`python3 specs/detection/reference_evaluator.py` evaluates every case in `specs/detection/evals/contract_amendment_escalation.jsonl`. Rust output must equal the full expected object byte-for-byte after canonical JSON serialization.
