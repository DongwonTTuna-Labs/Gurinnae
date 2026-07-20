# AI-agent runtime live review (2026-07-20)

Authority: `gurine-codex-authority-pack-v13.0.0-20260712.zip` only
(`sha256:960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
This is an independent, read-only review. No application source was changed by
this review; only this review record was added.

## Verdict

```text
AI_VERDICT: CHANGES_REQUIRED
```

The repository has substantial implementation for source-bound multimodal
extraction, agent policy/lineage, typed analysis projections, human decisions,
and five communication adapters. The current submission is not a proven
end-to-end runtime, however. The evidence root is not frozen and the only
CAS-010/CAS-011 runtime observations are blocked/error observations. In
addition, the current DB-to-API projection does not preserve the closed V2
agent output contract.

## Blocking findings

### 1. Evidence and source freeze is invalid

The current `sha256sum --check MANIFEST.sha256` exits 1 with 25 mismatches,
including `query_analysis_detail.rs`, both CAS screen fixture/snapshot sets,
the generated Control API schemas, and the runtime-trace test. The authority
tree digest command exits before computing a digest:

```text
MANIFEST mismatch before tree digest: apps/review-console/src/lib/server/screen-load.ts
```

The checked-in journey receipts also bind different source trees even though
their local `pass` values are true:

| Receipt set | `sourceTreeDigest` |
|---|---|
| `flow-01` … `flow-07` | `27300c584021ee4b5b4d27562490d50c2e5d630259f2e5c01c409b779a88e5cf` |
| `flow-08` … `flow-10`, `pdm-003` | `65621dbb71edf24ebd2edcde8e4b301a9fec2cdb0dd18d506b76a9a09bb53674` |

Until the final source, manifest, receipts, and archive are regenerated as
one digest, no runtime result can be treated as evidence for the submitted
artifact.

### 2. CAS-010/CAS-011 have no positive authenticated runtime evidence

`implementation-evidence/runtime-traces/cas-010.json` and `cas-011.json`
both report `ssrStatus: 200` but every section has
`projectionState: "BLOCKED"` and `observation.errorSummary: true`. They do
not show a successful authenticated Control API response, a typed
`analysis-vm.cas-010.v2`/`analysis-vm.cas-011.v2` envelope, or a rendered
metric/table/provenance graph.

The rich CAS response in `tests/e2e/support/mock-api-reads.ts:197-310` is a
test fixture with synthetic `a…`, `b…`, and `c…` digests. It is not a DB/API/UI
runtime receipt and does not prove that the same facts reach the Svelte DOM.
The UI adapters (`packages/ui/src/view-models/cas-011.ts:93-123` and
`apps/review-console/src/lib/view-models/cas-011.ts:115-146`) accept digest
strings but do not independently verify graph/table/set parity. A positive
trace must capture the authenticated request, response envelope, recomputed
digests, accessible table rows, graph rows, and rendered DOM for both screens.

### 3. Closed V2 output is not mapped losslessly into CAS-011

The worker validates and persists the closed V2 output (`summary`, `outcome`,
`investigationsPerformed`, `unknowns`, `nextActions`, and each agent-specific
field) in `ops.agent_runs.output_payload` and records validation in
`ops.agent_output_validations` (`services/analysis-worker/src/analysis_provider_output_validation.rs:24-57`).
The Control API then reads the raw payload (`services/control-api/src/service/query_dispatch.rs:140-158`),
but the projection uses a different contract:

* `services/control-api/src/service/query_analysis_detail.rs:64-84` reads
  `output.answerFirstSummary`, which is absent from the persisted V2 payload
  (`summary` is the authority field). A successful run therefore renders a
  null answer summary.
* The same function only copies `hypotheses`, `counterEvidence`, `unknowns`,
  `investigationsPerformed`, and `nextActions`. It drops market
  `comparables`, skeptic `challenges`, investigator `tasks`, claim-drafter
  `claims` and `communications`, and citation-verifier `claimResults`, all of
  which are required output fields (see
  `specs/agents/addendum-v2/schemas/*-output.schema.json`).
* V2 `unknowns`/`nextActions`/`investigationsPerformed` are structured
  objects, while `analysis-vm.schema.json:801-870` requires VM `unknowns` to be
  strings and requires the other arrays to retain their typed object shape.
  No normalization or fail-closed projection is present.
* `build_decisions` (`query_analysis_detail.rs:112-125`) hard-codes every
  proposal to `proposalType: TASK` and a generic summary. It does not expose
  the persisted proposal type, payload/citation-set digest, version, or the
  communication endpoint handoff needed for an informed approval.
* `build_view_model` hard-codes safety to
  `promptInjectionState: NOT_RUN`, `personalDataState: NOT_RUN`,
  `rightsState: UNKNOWN`, and `classificationState: LOCAL_ONLY`
  (`query_analysis_detail.rs:184-191`) instead of projecting validated
  policy, content-safety, rights, and classification dispositions. A UI can
  therefore display “not run/unknown” after the worker has actually passed or
  blocked those checks.

This is a semantic data-loss bug, not merely missing screenshot evidence. It
must be fixed and demonstrated with at least one non-empty output for every
agent-specific field plus a policy/rights-blocked run.

### 4. Multimodal → analysis → DB → UI path is not demonstrated

The source-bound parser and OCI process lifecycle evidence are concrete:
`implementation-evidence/media-runtime/runtime-evidence.json` and
`process-lifecycle-evidence.json` bind FFmpeg/ffprobe/Tesseract/whisper to OCI
digest `sha256:9f33d67998fb1333b93fcf5f190a2e871c3c6595c52a442596fc911de26024ad`,
and all timeout/output-limit/process-group/direct-child-reap cases are PASS.
`services/document-extractor/src/multimodal.rs:204-271` also binds each
segment/shot to asset revision and content digest.

Those artifacts prove parser/runtime capability only. No current evidence
joins a real image/audio/video input to persisted extraction rows, an agent
run, V2 hypotheses/unknowns/next actions, and a positive CAS-011 render. The
acceptance scripts (`scripts/test-analysis-runtime.sh` and
`scripts/test-analysis-production-egress.sh`) contain such checks, but no
current receipt records their execution against the final source digest.

### 5. Approval/omnichannel implementation lacks a current positive delivery
receipt

Static code supports the requested path:

* typed Telegram, WhatsApp, LINE, SMS, and Kakao adapters are enumerated in
  `services/egress-gateway/src/communication_adapter.rs:14-44`;
* authenticated SMS/Kakao polling and fail-closed unsupported polling are in
  `:225-290`, with scheduler production and stable dedupe keys in
  `services/scheduler/src/scheduler.rs:318-385`;
* the notification worker persists a provider-poll source receipt and emits a
  typed delivery observation (`notification_typed_poll_requested_body.rs:56-99`);
* egress checks provider config/preflight/secret-reference revisions before
  I/O (`services/egress-gateway/src/handlers/mod.rs:358-400`);
* the credential resolver runtime probe is PASS and records no raw token in
  `implementation-evidence/credential-resolver-runtime.json`.

No current runtime evidence covers the complete
agent COMMUNICATION proposal → human yes/no decision → immutable rendering →
queue → provider request → callback/poll → terminal delivery receipt path for
any channel. `flow-08` proves a generic high-impact action/step-up decision,
not an AI communication proposal or provider delivery. The required evidence
must prove all five channels (callback for Telegram/WhatsApp/LINE and
authenticated poll for SMS/Kakao), replay/conflict behavior, consent and
suppression checks, and that approval never implies delivery.

## Capability matrix

| Capability | Source inspection | Current runtime evidence | Result |
|---|---|---|---|
| Multimodal extraction and process safety | Implemented and digest-bound | OCI lifecycle PASS | Partial; no DB/UI journey |
| Snapshot/tool/citation policy | Implemented in worker/orchestration | Analysis scripts exist | Partial; no current receipt |
| V2 output persistence | Worker validation and DB persistence present | No projection readback | **FAIL** (mapping loss) |
| CAS-010 visualization/table | Typed VM and accessible table code present | Trace is BLOCKED | **FAIL** |
| CAS-011 provenance graph/table | Graph/set digest code present | Trace is BLOCKED; fixture only | **FAIL** |
| Hypotheses/unknowns/next actions | Persisted in V2 output | API drops/reshapes fields | **FAIL** |
| Human approval and decisions | Owner routines and UI actions present | No AI communication receipt | Partial |
| Telegram/WhatsApp/LINE/SMS/Kakao | Typed adapters and revision fences present | No channel delivery matrix | Partial |
| Source/manifest/archive binding | Authority hash known | Manifest and digest fail | **FAIL** |

## Required remediation and re-review evidence

1. Freeze implementation edits, regenerate `MANIFEST.md` and
   `MANIFEST.sha256`, and require a clean checksum plus successful
   `scripts/authority_tree_digest.py`.
2. Fix the CAS-011 mapper against the exact V2 schemas. Preserve
   `summary→answerFirstSummary`, `outcome/status`, unknowns, investigations,
   next actions, every agent-specific result, typed proposal metadata, and
   validated safety/rights dispositions; reject malformed payloads instead of
   silently substituting `NOT_RUN`/`UNKNOWN`.
3. Seed a real PostgreSQL completed run and an abstained/blocked run. Capture
   authenticated positive CAS-010 and CAS-011 traces with one final source
   digest, including chart/narrative/table digest equality, provenance graph
   and `accessibleRows` equality, output fields, safety state, and rendered
   DOM/accessibility evidence.
4. Run one unchanged-source multimodal journey from asset bytes through
   extraction, source-use/citation lineage, V2 output persistence, Control API,
   and CAS-011 UI. Preserve the DB query/readback and all correlation/digest
   receipts.
5. Run the AI COMMUNICATION proposal/approval/delivery matrix for Telegram,
   WhatsApp, LINE, SMS, and Kakao, including callback/poll, replay/conflict,
   suppression/consent, provider revision, terminal receipt, and explicit
   “approval is not delivery” assertions.
6. Regenerate all journey/PdM receipts from the one final digest, recreate the
   source archive, verify clean extraction/manifest parity, then request this
   independent review again. Until these are complete, do not report
   `AI_VERDICT: LGTM_NO_BLOCKING` or `VERDICT: ARTIFACT_READY`.

