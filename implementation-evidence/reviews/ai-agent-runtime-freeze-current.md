# AI-agent runtime freeze review (2026-07-20, independent)

Authority: `gurine-codex-authority-pack-v13.0.0-20260712.zip` only
(`sha256:960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
This is a read-only review of the current working tree and checked-in runtime
evidence. No implementation source was changed by this review.

## Verdict

```text
AI_VERDICT: CHANGES_REQUIRED
```

The implementation contains real agent, lineage, multimodal, approval,
omnichannel, and CAS visualization code. The freeze is nevertheless invalid:
the current source/evidence/archive set is not hash-consistent, and the
checked-in CAS runtime traces do not prove a positive current render.

## Blocking findings

### 1. Current MANIFEST and authority tree digest fail

`sha256sum --check MANIFEST.sha256` currently reports 21 failures:

```text
apps/review-console/src/lib/server/screen-load.ts
db/migrations/0030_v13_submission_session_hardening.sql
implementation-evidence/reviews/product-design-r4-current.md
packages/ui/src/screen-contract.test.ts
packages/ui/src/screen-projection-specialized.ts
packages/ui/src/view-models/ops-004.ts
services/control-api/src/service/query_addendum_queue.rs
services/control-api/src/service/query_analysis_detail.rs
services/control-api/src/service/query_analysis_vm.rs
services/control-api/src/service/query_business.rs
services/control-api/src/service/query_dispatch.rs
specs/api/control-api.openapi.yaml
specs/api/resource-schemas.yaml
tests/e2e/screen-runtime-traces.spec.ts
tests/e2e/support/mock-api-reads.ts
tests/e2e/visual-routes.spec.ts-snapshots/cas-010-{compact,medium,wide}-chromium-linux.png
tests/e2e/visual-routes.spec.ts-snapshots/cas-011-{compact,medium,wide}-chromium-linux.png
```

The authority-tree digest command therefore exits with
`MANIFEST mismatch before tree digest: apps/review-console/src/lib/server/screen-load.ts`.
An independent recomputation of the generator's source digest (excluding
`implementation-evidence/` and the two circular manifest files) is
`bb95e4205c6f8ca1b8a83a068cf0fa4212c80cc63c149134e55eedd46a951628`, while
the journey receipts are split between `27300c584021ee4b5b4d27562490d50c2e5d630259f2e5c01c409b779a88e5cf`
and `65621dbb71edf24ebd2edcde8e4b301a9fec2cdb0dd18d506b76a9a09bb53674`.

### 2. Runtime journey evidence is from multiple source freezes

`implementation-evidence/runtime-journey-receipts/flow-01` through `flow-07`
carry source digest `27300c...e5cf`; `flow-08` through `flow-10` and
`pdm-003-observability` carry `65621db...3674`. The receipts' local `pass`
fields do not repair this binding mismatch. They must all be regenerated from
one final source digest after the manifest is regenerated and verified.

### 3. CAS-010/CAS-011 checked-in traces are blocked/error observations

`implementation-evidence/runtime-traces/cas-010.json` and `cas-011.json` both
have `errorSummary: true`; every recorded section is `projectionState:
BLOCKED`. They do not demonstrate the current positive API → typed projection
→ accessible visualization/provenance path. The current E2E test fixture does
contain a rich CAS envelope (`tests/e2e/support/mock-api-reads.ts`), and source
projection code is present, but that test observation is not persisted as a
positive runtime trace bound to the final source digest. Regenerate and retain
positive authenticated CAS-010 and CAS-011 traces, including metric/table and
graph/accessibility digest parity.

### 4. Existing archive is stale and fails its own manifest

`artifacts/gurine-source-v13.0.0.tar.gz` exists, but extracting it and running
its embedded `MANIFEST.sha256` produces 40+ failures (including the current
CAS projection, control API, generated schema/client, and runtime-test files).
Selected bytes also differ from the working tree (`screen-load.ts` archive
`c297e1...` vs current `5de6c6...`; migration 0030 archive `104039...` vs
current `8fc22e...`). Recreate the archive only after the source/evidence
freeze, then run clean-extraction verification with the final evidence root.

### 5. CAS-011 projection has an output-contract mapping gap

`services/control-api/src/service/query_analysis_detail.rs` currently reads
`answerFirstSummary` and camel-case arrays from `output`, while the analysis
worker's persisted closed V2 output uses `summary`, `outcome`,
`investigationsPerformed`, `nextActions`, `abstentionReasons`, and agent-specific
arrays (see `analysis_agent_jobs.rs`/`analysis_helpers.rs`). Consequently a
successful real run can render a null summary and empty arrays even though the
validated output contains hypotheses, unknowns, or next actions. The safety
projection also defaults to `NOT_RUN`/`UNKNOWN` instead of projecting a
validated safety disposition. CAS-011 is the required surface for structured
output, safety, and human decisions. A positive runtime run must prove the
actual persisted V2 fields survive DB → API → view model → UI (or fail closed
with an explicit unknown reason); a fixture containing only a summary is
insufficient.

## Capability review (non-blocking once freeze is repaired)

- The read-only five-agent policy and abstention gates are implemented in
  `crates/agent-orchestration/src/policy.rs`: tool allowlists, snapshot
  equality, budget/provider checks, citation existence/locator matching, and
  prompt-injection denial are enforced.
- `services/analysis-worker/src/analysis_runtime_bridge.rs` binds provider
  output to a repeatable-read snapshot and selected-content hashes, bounds
  turns/tool calls, persists typed source-use/tool receipts, and rejects
  citations outside the snapshot. `analysis_provider_output_validation.rs`
  records output/citation/proposal digests and immutable proposal citations.
- Source research fetch is gateway-bound, size/media-type bounded, scans
  untrusted content, stores redacted locator/artifact metadata and content
  hashes, and records rights/policy receipts (`analysis_source_fetch.rs`).
- CAS visualization/provenance implementation exists in
  `services/control-api/src/service/query_analysis_vm.rs`,
  `query_analysis_detail.rs`, and `query_analysis_provenance.rs`; the UI has
  typed CAS view models and accessible table/graph rendering. The digest unit
  test is present in `query_analysis_vm_tests.rs`.
- Multimodal media/OCR execution uses pinned runtime paths, process groups,
  bounded output, timeout, group termination, and direct-child reaping
  (`services/document-extractor/src/common.rs` and media adapters). The
  checked-in OCI lifecycle evidence is PASS for FFmpeg, ffprobe, Tesseract,
  and whisper and binds image digest
  `sha256:9f33d67998fb1333b93fcf5f190a2e871c3c6595c52a442596fc911de26024ad`.
- Communication adapters cover Telegram, WhatsApp, LINE, SMS, and Kakao;
  authenticated provider polling is limited to SMS/Kakao and maps unknown
  provider state to reconciliation. Notification worker records immutable
  provider-poll receipts and binds delivery to provider config/preflight
  revisions. Egress callback code verifies signatures, SMTP content type/MTA
  assertion, callback replay, and revision/preflight binding.
- Credential resolution is fail-closed on missing/version-unpinned reference,
  source-marker mismatch, and missing token; the current runtime probe records
  matching-reference PASS and raw-token non-persistence/non-logging.

## Required re-review gate

1. Stop evidence generation and freeze the final source tree.
2. Regenerate `MANIFEST.md`/`MANIFEST.sha256`; require clean checksum and
   successful `scripts/authority_tree_digest.py`.
3. Regenerate all journey/PDM receipts from the resulting single digest and
   persist positive CAS-010/CAS-011 runtime traces.
4. Re-run all relevant runtime/acceptance gates, then regenerate the manifest
   once more and confirm it remains clean.
5. Recreate `artifacts/gurine-source-v13.0.0.tar.gz`, verify sidecar/member and
   clean extraction parity, and run the archive verifier with its evidence
   root.
6. Request this independent AI review again against the unchanged final
   digest.

Until all six steps pass, `AI_VERDICT: LGTM_NO_BLOCKING` and
`VERDICT: ARTIFACT_READY` are forbidden.
