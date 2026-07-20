# AI/runtime review R2

## Scope

Authority inputs were limited to the authority-v13 snapshot's CODEX handoff /
start / agent / build / verify documents, base specs, and database migrations
0001–0024. No prior Gurinnae material or non-authoritative specification was
used. Within that scope, reviewed closed provider-tool V2 decoding, immutable
snapshot binding, source-use lineage, provider receipt binding, object-store
replay, scanner and cost settlement.

The authority ZIP SHA-256 is
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`.
The current source-tree manifest was revalidated on 2026-07-19 UTC with
`scripts/authority_tree_digest.py`: `ea6212017a626aa9f6c85f552919bc9bf4a312e43692b2890c4e4fcfddb62748`
(4,201 manifest entries). A digest change invalidates this verdict and requires
the runtime checks below to be rerun.

The reviewed implementation units had these content digests at review time:

```text
services/analysis-worker/src/analysis_provider_lineage.rs cc08cc91900a761c9e5ffdad0f8db34cc53f8394661351310d052c66d6f71e95
services/analysis-worker/src/analysis_research_lineage.rs 0bdbe78f8280f5c043ed7484478ee68f275e509e35b4752ba53900cf33befa44
services/analysis-worker/src/analysis_provider_output_validation.rs ad7b1a6da28ee7d46edd8e24263d9236f8ef4c755e88509b61014c009fc2b6bf
crates/test-support/src/runtime_probe.rs 70c07278d2e2052645de95314265a814774a59c8409b95cc2558e51c305dfbd0
```

## Review loop

An initial runtime run exposed two implementation defects. First, the database
receipt trigger treated `TOOL_RESULT` rows as receipt-bound even though the
contract only makes `MODEL_OUTPUT_DERIVATION` receipt-bound. Second, the
validation upsert used a malformed/unsupported `ON CONFLICT ... DO UPDATE`
projection. Both were corrected at their source; the trigger now enforces the
receipt lookup only for `MODEL_OUTPUT_DERIVATION`, and validation persistence
uses `DO NOTHING RETURNING` followed by an existing-row lookup.

The temporary diagnostic exception text was removed. Production behavior keeps
the generic `SOURCE_USE_PROVIDER_RECEIPT_MISMATCH` error.

## Evidence

- `cargo check -p gurine-analysis-worker --locked`: PASS.
- `bash scripts/test-analysis-runtime.sh` (2026-07-19T15:32:58Z): PASS —
  `10-rule/5-agent/provider-test budget-tool-citation PostgreSQL analysis runtime: PASS`.
  This run covered provider turns, TOOL_QUERY/TOOL_RESULT/MODEL_INPUT/
  MODEL_OUTPUT_DERIVATION/CITATION lineage, output validation, budget ledger,
  provider connection test, and credential redaction.
- `bash scripts/test-analysis-production-egress.sh` (2026-07-19T15:33:16Z): PASS — production-mode
  provider egress, durable source/artifact lineage, validation, budget ledger,
  and credential redaction. Deterministic pre-dispatch `MODEL_INPUT` rows are
  kept distinct from terminal receipt-bound projections; the smoke gate checks
  terminal receipt matches, exact `MODEL_OUTPUT_DERIVATION` bindings, and the
  RFC8785 canonical digest of every persisted source-use root.
- `bash scripts/test-analysis-negative-runtime.sh` (2026-07-19T15:41:56Z):
  PASS — budget/prompt-injection/stale-snapshot/invalid-scope fences, AI-disabled
  policy, provider retry exhaustion, redacted dead-letter evidence, and expired
  lease recovery.
- Egress restart smoke: PASS. After a gateway restart, the same idempotency
  key read the durable `egress-replay/<sha256>` object and returned
  `x-gurine-egress-replayed: true` with byte-equivalent body, payload digest,
  receipt ID, and receipt digest; the upstream was not called again.

## Verdict

`VERDICT: LGTM_NO_BLOCKING`
