# Provider runtime closure evidence

This evidence records the provider-turn persistence slice implemented against
the v13 authority addendum. It is not a substitute for the full runtime gate.

## Completed in this slice

- `ops.agent_provider_turns` receives the v2 run/provider/cost foreign keys and
  the one-completed-winner partial unique index in migration `0030`.
- Analysis-worker terminal writes call the fixed-search-path
  `ops.complete_agent_provider_turn` owner function. Direct worker `UPDATE` is
  denied by the role ACL.
- The persisted redacted request is the exact JSON body sent to the egress
  gateway; objective/evidence payloads pass the repository redaction helper.
- Network, malformed response, missing/invalid receipt, unknown outcome,
  pricing, budget and output-schema failures append an `OUTCOME_UNKNOWN`
  terminal turn through the same owner function before the job is retried.
- Owner validation covers the ProviderReceiptV2 root/usage/pricing/data-policy
  shape, canonical receipt/turn/envelope/error digests, version CAS and
  outcome/status parity.

## Verification

- `cargo check -p gurine-analysis-worker --locked` — PASS
- `cargo test -p gurine-analysis-worker --locked` — PASS (0 tests defined)
- PostgreSQL 18.4 runtime: migration fragment applied; FK/index/function owner,
  fixed search path and worker EXECUTE ACL inspected successfully.
- PostgreSQL 18.4 runtime: `SET ROLE gurine_analysis_worker; UPDATE
  ops.agent_provider_turns ...` fails with `permission denied`.

## Remaining cross-surface gates

AgentRunV2 start/transition ownership, budget reservation settlement, tool and
source-use provenance, typed control/API projections, provider adapter receipt
generation, and browser/UI approval closure remain separate gates owned by the
corresponding runtime slices. No overall LGTM is implied by this evidence.
