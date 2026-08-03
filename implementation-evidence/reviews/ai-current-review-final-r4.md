# AI/runtime fresh re-review — current working tree (2026-07-20)

권위 입력은 `gurine-codex-authority-pack-v13.0.0-20260712.zip` 단일 파일이다
(`sha256:960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
리뷰어는 source/spec/DB를 수정하지 않았고, 이 파일만 evidence로 추가했다.

## VERDICT

```text
AI_VERDICT: CHANGES_REQUIRED
```

## Rechecked

- `python3 -B specs/agents/reference_harness.py`: `total=50`, `result=PASS`.
- `python3 -B specs/agents/addendum-v2/validate_contracts.py --self-test`: `SELF_TEST: PASS`.
- `cargo check -p gurine-analysis-worker`: PASS.
- `cargo test -p gurine-analysis-worker --lib`: 5/5 PASS.
- `cargo check -p gurine-egress-gateway`: PASS.
- `bash scripts/test-analysis-runtime.sh`: PASS (`10-rule/5-agent/provider-test budget-tool-citation PostgreSQL analysis runtime`).

These are compile/harness/analysis-runtime observations only; they do not prove
the external source-fetch acceptance matrix or a clean final archive.

The latest source snapshot corrected the asset-rights canonical version and
removed the extra gateway-receipt artifact field. Those two checks are retained
below as resolved observations; the remaining rights, hold, receipt, network,
claim, and freeze findings still block approval.

## Blocking findings

### R4-001 (resolved in latest snapshot) — asset-rights/source-use canonical version mismatch

`services/analysis-worker/src/analysis_source_fetch.rs` builds the root
`rightsDecision` with `decisionVersion: 1` (the newly created asset-rights row),
while `ops.record_research_fetch_v1` in
`db/migrations/0030_v13_submission_session_hardening.sql` hashes the canonical
source-use object with `decisionVersion = v_capability_version`. The same function
persists `asset_rights_decision_version = 1`. Any active capability decision whose
version is not exactly one therefore produces a digest different from the worker's
`p_source_use_sha256` and fails with `SOURCE_USE_DIGEST_MISMATCH`.

The latest migration now uses asset-rights `decisionVersion: 1` in this canonical
object, with capability version carried separately. A DB integration run with a
capability version greater than one is still required as proof.

### R4-002 — source rights are still projected/synthesized from capability

`ops.assert_research_fetch_rights_v1` returns a SOURCE_ACCESS capability and
hard-codes `accessRight`/`privateStorageRight` to `ALLOW`; model rights are inferred
from the existence of a MODEL_EGRESS/PAID_WORKSPACE_PROCESSING capability. The
record function then creates a new `raw.asset_rights_decisions` row from those
values. This is not an owner-supplied exact asset decision FK/revision/digest and
does not validate a current robots/rate-policy receipt or an exact source asset
rights grant before dispatch. Capability admission and asset-rights permission must
remain separate, and UNKNOWN/DENY/expired/held assets must fail closed.

### R4-003 — legal-hold lock domain is not guaranteed to match source admission

The fetch preflight locks `hashtextextended(p_source_id, 13)`, while hold placement
locks `objectId`, `caseId`, and each `affectedIds` value. A hold over a source asset,
research artifact, case, or anchor whose UUID/string is not exactly the external
`source_id` does not contend on the same advisory key. The preflight is a separate
transaction from the gateway dispatch, so a hold can still commit after admission
and before the external request. A shared canonical lock-key set plus authenticated
hold/anchor snapshot receipt is required.

### R4-004 — gateway/source receipt does not bind the complete network policy

The worker now sends max-byte/media-type/request-digest headers and the gateway
echoes them, but the request's policy/capability/rights snapshot is still not a
cryptographically bound capsule. The gateway receipt digest includes body, status,
request digest, counters, and redirect JSON, but does not bind the source rights
decision/activation digest or a complete per-hop DNS/policy proof. The receipt is
also not persisted into the research-artifact/source-fetch rows (see R4-009).

Reqwest's default decompression also means `content_length` is not a reliable
compressed-byte counter; ratio-100 enforcement is not proven. The worker client
still has a 120-second timeout while authority requires a 15-second total timeout.

### R4-005 — Brave discovery silently drops invalid URLs

The closed `deny_unknown_fields` decoder now rejects schema drift, but the mapping
uses `filter_map` for URL parse/scheme failures and silently omits invalid results.
This can turn a provider/policy-invalid response into a partial or empty success
without a typed rejection receipt. Invalid required result URLs must produce the
authority's typed policy/schema failure (or an explicit, digest-bound rejection
ordinal), not silent omission.

### R4-006 — current source freeze is not valid

At review time `sha256sum --check MANIFEST.sha256` fails for:

```text
db/migrations/0030_v13_submission_session_hardening.sql
services/analysis-worker/src/analysis_source_fetch.rs
services/control-api/src/service/query_business.rs
services/control-api/src/service/specialized_group_6.rs
verification/generated-operation-samples.json
```

`scripts/authority_tree_digest.py` consequently stops at the MANIFEST mismatch.
The journey/PDM receipts currently claim source digest
`8bae4389de93f5875b24815b12572e086a0d4b3607acd77b563454088a45c060`, which cannot
be accepted as a digest for this unverified working tree. Regenerate MANIFEST,
tree digest, all runtime/CAS/PDM receipts, and clean-extraction archive together.

### R4-007 — legacy suggestion projection is not explicitly isolated

`services/analysis-worker/src/analysis_job_persistence.rs` still inserts an
`ops.agent_suggestions` row for every completed V2 agent output. The row has no
compatibility-projection/version marker and is written alongside the typed V2
proposal path. The analysis runtime script merely proving that five legacy rows
exist does not prove the authority's single typed `AgentProposalV2` set equality;
the projection must be explicitly compatibility-only and excluded from proposal
parity, or the opaque insert must be removed.

### R4-008 — hold-anchor evidence is not part of fetch preflight

`assert_research_fetch_rights_v1` checks `editorial.legal_holds` and affected IDs,
but does not resolve `ops.legal_hold_target_anchors` or bind an authenticated
target/version/anchor coverage digest to the dispatch reservation. Placement and
release-side anchor checks cannot substitute for the exact hold-anchor snapshot
used by the fetch admission.

### R4-009 — authenticated gateway receipt is not persisted

`PendingSourceFetch` and `record_research_fetch_v1` carry `p_receipt_digest` as the
content-safety receipt. The gateway's authenticated receipt ID/digest and its
compressed/expanded counters, DNS proof, and policy proof are not carried into the
research artifact/source-fetch or ToolCall adapter receipt rows. Consequently an
HTTP payload can reach artifact persistence without the required authenticated
gateway receipt binding.

### R4-010 — ToolCall claim still stores a synthetic rights digest

`services/analysis-worker/src/analysis_runtime_bridge.rs::claim_tool_call` binds
`rights_decision_sha256` to `sha256("rights-allow")` for every tool, including
`source.fetch`, before the real capability/asset-rights result is loaded. This is
not an exact owner decision/version/digest and lets a claimed call carry a fake
rights receipt. The claim must bind the exact rights snapshot or remain blocked
until that owner decision is resolved.

### R4-011 (resolved in latest snapshot) — FETCH_URL wire response now violates its closed schema

The latest `build_fetch_output` adds `gatewayReceiptSha256` directly to each
`artifact`. `SourceFetchResponseV2`/`SourceArtifactV2` and the authority
`source-fetch.response.schema.json` use `deny_unknown_fields` and did not define
that property. The latest source removed the extra artifact field. Gateway receipt
proof still needs to be persisted through an authorized receipt path (R4-009).

## Gate

Until the remaining R4-002 through R4-010 findings are resolved and a fresh unchanged-source review passes,
`AI_VERDICT: LGTM_NO_BLOCKING` and `VERDICT: ARTIFACT_READY` are forbidden.
