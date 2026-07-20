# AI-agent runtime / omnichannel independent review (2026-07-19, final-freeze audit)

Authority: `authority-v13` only. Read-only review of the current working tree,
runtime evidence, and source archive. No implementation files were changed.

## Verdict

```text
VERDICT: CHANGES_REQUIRED
```

## Blocking findings

The submitted tree is not currently frozen and therefore no AI-runtime or
archive LGTM can be issued:

- The required AnalysisVm visualization/provenance surface is not implemented
  in the current source. Authority schemas require
  `analysis-vm.cas-010.v2`/`analysis-vm.cas-011.v2` with `visualizations`, and
  CAS-011 additionally requires `ProvenanceGraphV2` (`graphSha256`,
  `accessibleRows`, and `accessibleRowsSha256`). A repository-wide source
  search finds no implementation or test producer for
  `VisualizationVmV2`, `ProvenanceGraphV2`, `visualizationSetSha256`,
  `graphSha256`, or `accessibleRows`. The CAS-010/011 routes and UI bindings
  expose only generic `runs`/`identity`/`inputs`/`output` fields, and the
  `getAgentRun` SQL projection returns source-use/citation rows but no typed
  visualization set or provenance graph. The authority feature explicitly
  requires chart, narrative, accessible-table, and graph digest/fact parity;
  schema presence alone is not a runtime implementation.

- `sha256sum --check MANIFEST.sha256` fails for 11 current files:
  `implementation-evidence/runtime-journey-receipts/flow-01` through
  `flow-10` and `pdm-003-observability` (all dated `20260719`).
- `scripts/authority_tree_digest.py` stops at `flow-01-20260719.json` with a
  manifest mismatch. The current receipt files were modified after the
  manifest (`MANIFEST.sha256` mtime 22:31 UTC; receipt mtime 22:39 UTC).
- The affected receipts do not share one source digest: flows 01–05 report
  `bec499dc42d2f30a8f86e6a45bed6f7178cfbfa63b02fa9f4f3f62c924c569ef`, while
  flows 06–10 and `pdm-003` report
  `bd728425460670e8e1464996219178e8cf7776f193e56766000528bc0c2ae9e8`.
  This violates same-freeze evidence binding even though each receipt's local
  `pass` field is `true`.
- The existing source archive is therefore not evidence of the current tree;
  its clean-extraction verification cannot establish the current receipt
  bytes until the source/evidence set is frozen and the manifest/archive are
  regenerated.
- An independent run of `scripts/verify_source_archive.py` also reaches the
  clean extraction but fails `make verify-final` immediately because
  `ACCEPTANCE_EVIDENCE_ROOT is required`. The archive gate must provide the
  extracted evidence root (or make the verifier derive it) before a clean
  archive PASS can be claimed.

## Review observations (non-blocking once freeze is repaired)

- Multimodal ingestion is concretely implemented for WAV/WebM: pinned FFmpeg,
  ffprobe, Tesseract, whisper.cpp/model hashes, bounded stdout, timeout,
  process-group termination, and direct-child reaping are present in the
  current source. The final OCI process probe records PASS for all four
  components and matches digest
  `sha256:9f33d67998fb1333b93fcf5f190a2e871c3c6595c52a442596fc911de26024ad`.
- Agent output validation and source-use persistence bind snapshots, tool
  receipts, citations, rights decisions, provider turns, and canonical
  SHA-256 digests. Visualization/provenance schemas require accessible table
  alternatives and graph digest binding.
- Human approval is explicit in the Svelte approval dialog and typed
  communication worker path. Delivery requires an approved rendering,
  provider/preflight/config revision binding, consent/context checks, and an
  immutable receipt. SMS/Kakao authenticated polling stores a non-projecting
  source receipt first, then applies a typed observation; stable poll keys are
  deduplicated by the outbox function.
- Credential resolution requires a version-pinned reference, exact source
  marker equality, and a non-empty token; the live resolver evidence records
  matching-reference PASS, mutable/plaintext rejection, mismatch rejection,
  and raw-token non-persistence/non-logging.

## Required re-review gate

1. Stop all receipt/evidence generation and freeze the final source tree.
2. Regenerate `MANIFEST.md` and `MANIFEST.sha256`; require a clean
   `sha256sum --check MANIFEST.sha256` and successful
   `scripts/authority_tree_digest.py`.
3. Regenerate all runtime receipts from that one digest (including PDM-003),
   then regenerate the manifest again and verify it remains clean.
4. Recreate the source archive and run clean-extraction verification against
   the regenerated archive; confirm archive member set and manifest parity.
5. Re-run this independent AI-runtime review against that unchanged digest.
