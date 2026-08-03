# AI agent/runtime independent review (2026-07-20, current tree)

Authority: `gurine-codex-authority-pack-v13.0.0-20260712.zip` only
(`sha256:960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
This is a read-only review. No Rust, SvelteKit, SQL, or test implementation was
changed by the reviewer; this markdown record is the only review output.

## Verdict

```text
AI_VERDICT: CHANGES_REQUIRED
```

The current source has substantial agent lineage, multimodal process bounds,
typed human approval, and provider-specific omnichannel code. The authority
hard gates are not closed, so an AI/runtime LGTM and `ARTIFACT_READY` are not
warranted.

## Blocking findings

### AI-RUNTIME-R2-001 — source/evidence/archive freeze is not valid

`sha256sum --check MANIFEST.sha256` currently fails for 12 files: the ten
`implementation-evidence/runtime-journey-receipts/flow-01..10-20260719.json`
files, `pdm-003-observability-20260719.json`, and
`packages/api-client-control/src/generated/types.gen.ts`.
`python3 -B scripts/authority_tree_digest.py` stops at `flow-01-20260719.json`
with a manifest mismatch. The authenticated CAS traces contain no source-tree,
view-model, visualization-set, graph, or accessible-row digest binding, and
CAS-010 still records `PARTIAL` states for runs/filters/suggestions/budget.

`artifacts/gurine-source-v13.0.0.tar.gz` is stale relative to the current tree:
the archive SHA is `426dce1c15ca57817722a69e00ca6a2b2756ea9aeff385ea68e8e1d166988169`
(sidecar from the previous freeze), while the current
`analysis_source_fetch.rs` and migration `0030_v13_submission_session_hardening.sql`
hashes differ from their archived members. A manifest/tree digest failure and a
stale archive cannot prove the reviewed implementation.

Required: stop receipt generation, freeze one source tree, regenerate manifest
and all journey/CAS evidence from one digest, then recreate and clean-extract
verify the archive.

### AI-RUNTIME-R2-002 — FETCH_URL can create synthetic rights under a legal hold

`services/analysis-worker/src/analysis_source_fetch.rs:58-69` only calls
`ops.research_fetch_capability_ready_v1(source_id, request_kind)`. That routine
(`db/migrations/0030_v13_submission_session_hardening.sql:2254-2276`) checks an
active `SOURCE_ACCESS` capability but does not bind an exact source asset/revision
rights decision or query active legal-hold/suppression anchors before egress.

The owner function
`ops.record_research_fetch_v1` (`0030_v13_submission_session_hardening.sql:2285-2490`)
then inserts a fresh `raw.asset_rights_decisions` row with all dimensions
`ALLOW`, `PUBLIC_RESEARCH`, a synthetic `license_evidence_digests` value, and a
deterministic timestamp derived from content bytes (`v_now` at lines 2357-2394).
It is not an owner-approved `(asset_id, revision, hash, decision_version,
decision_sha256)` reference. This permits an expired/denied/held URL to become a
model-usable ResearchArtifact after the network request and violates the
authority's rights/hold deny precedence.

Required: perform an owner-side serializable rights/hold preflight before
gateway dispatch; pass the verified rights identity into the record function;
reject synthetic rights, timestamps, reviewer, and license evidence.

### AI-RUNTIME-R2-003 — redirect and gateway capsule contract is incomplete

`read_source_response` (`services/analysis-worker/src/analysis_source_fetch.rs:104-154`)
issues one GET to the gateway and always returns an empty redirect array. A
request with `allowRedirects=true` is accepted by `source_target`, but the
gateway client is built with `reqwest::redirect::Policy::none()` and
`proxy` returns `EGRESS_REDIRECT_DENIED` (`services/egress-gateway/src/handlers/mod.rs:503-516`).
No redirect chain (up to five hops), per-hop canonical URL/DNS/IP/rights check,
or receipt is possible. The worker also sends only unscoped target/source/turn
headers rather than the authority's typed, HMAC-scoped method/URL/policy/byte
capsule and replay identity.

The authority network contract requires revalidation at every redirect and
streamed compressed/expanded byte counters with ratio 100. The current
`proxy_response_body.rs` compares `response.content_length()` to expanded body
after reqwest handling and has no authenticated per-request bound; this is not
evidence that the required fetch policy closes.

Required: implement the typed gateway capsule, bounded redirect chain with
per-hop policy/rights receipts, and streaming compressed/expanded counters;
exercise positive and negative redirect/ratio cases.

### AI-RUNTIME-R2-004 — deterministic provider double bypasses the selected authority schema

In test/development, `select_agent_output` (`services/analysis-worker/src/analysis_agent_jobs.rs:159-177`)
returns `deterministic_output` (`analysis_helpers.rs:286-304`), whose envelope is
only the common `status`, `abstention_reasons`, and `recommended_actions` shape
and omits the selected agent's required fixture fields (for example
`comparables`, `hypotheses`, `challenges`, `draft_claims`, or
`verification_results`).
`validate_agent_output_for` (`analysis_helpers.rs:395-406`) explicitly falls
back to the generic v1 validator when `schemaVersion` is absent. The authority
provider-double contract requires returning the declared fixture response (or
declared failure) and validating it before policy acceptance; this path can
report a completed run without exercising the production V2 contract.

Required: make the deterministic double load the pinned per-agent provider
fixture/closed authority schema, remove the generic fallback, and run all five agent
positive/negative fixture cases through the same validator and proposal path.

### AI-RUNTIME-R2-005 — Brave response schema drift is accepted as an empty success

`build_fetch_output` (`services/analysis-worker/src/analysis_source_fetch.rs:321-335`)
deserializes arbitrary JSON and maps only `web.results[].title/url/description`.
Unknown fields are ignored; a missing or non-array `web.results` is converted by
`unwrap_or_default()` into `searchResults: []` with a normal discovery receipt.
There is no closed required/optional decoder, provider truncation signal check,
or adapter-version rejection. A malformed/drifted provider response therefore
reaches the model as a valid zero-result discovery instead of
`PROVIDER_SCHEMA_DRIFT` and reconciliation.

Required: use an exact adapter-version response type with unknown-field and
required-field rejection, canonical URL/DNS policy checks, and a typed drift
receipt; never treat malformed results as an empty success.

## Verified non-blocking capabilities (recheck after fixes)

- Provider-turn receipts, source-use/citation lineage, budget settlement, and
  output validation are present in the Rust analysis worker and owner SQL path.
- CAS-010/CAS-011 typed visualizations, accessible tables, and provenance graph
  construction exist in `query_analysis_vm.rs` and
  `query_analysis_provenance.rs`; current traces do not bind them to the final
  source digest, so they cannot close the freeze gate yet.
- Document-extractor media/OCR execution has bounded output, timeout,
  process-group termination, direct-child reap, pinned FFmpeg/ffprobe/Tesseract/
  whisper runtime evidence.
- Typed Email/Telegram/WhatsApp/LINE/SMS/Kakao adapters, encrypted approved
  renderings, provider revision/preflight checks, authenticated SMS/Kakao polls,
  callbacks, idempotency, and reconciliation paths are present. These remain
  subject to the same final freeze and live evidence gate.

## Re-review requirements

1. Repair R2-002 through R2-005 and add the required negative/positive runtime
   evidence.
2. Freeze source/evidence, regenerate manifest and authority-tree digest, and
   regenerate positive CAS and journey receipts from that single digest.
3. Recreate the source archive, verify clean extraction/member parity, and rerun
   all AI/omnichannel hard gates.
4. Request a fresh independent review against the unchanged final digest.

Until then the exact approval string is intentionally withheld:
`AI_VERDICT: LGTM_NO_BLOCKING` is forbidden.
