# AI runtime / omnichannel independent review (2026-07-19, fresh source)

Authority: authority-v13 only.  This is a fresh review of the current source
tree and current runtime evidence; earlier AI-runtime verdicts are stale.

## Verdict

```text
VERDICT: CHANGES_REQUIRED
```

The queue, authenticated callback, authenticated provider-poll source-receipt
path, SMTP DSN integration binding, and pinned media artifact records are now
present.  The hard gate is still not closed because the pinned OCI artifact
predates the latest process-lifecycle source changes, and the
document-extractor golden test is not passing in the available test
environment.

## Evidence reviewed

### Provider poll and source receipt

- `services/notification-worker/src/notification_typed_poll_requested_body.rs`
  calls the typed egress poll endpoint, then calls
  `ops.record_provider_poll_source_receipt_v1` and forwards the immutable
  source receipt to `record_outbound_delivery_observation` through
  `communication.delivery_poll.v1`.
- `db/migrations/0030_v13_submission_session_hardening.sql` defines the source
  receipt owner with delivery-version fencing, replay/conflict keys, immutable
  `PROVIDER_POLL` receipt, audit row and typed outbox event.
- `services/egress-gateway/src/communication_adapter.rs` performs an
  authenticated provider-native poll for SMS/Kakao and rejects unsupported
  channels rather than fabricating a terminal state.
- `services/scheduler/src/scheduler.rs::schedule_delivery_poll_requests` now
  emits deduplicated poll requests for due SMS/Kakao deliveries, and
  `ops.enqueue_outbox` enforces the stable poll key.  This closes the prior
  missing-producer blocker; a clean scheduler/database live readback is still
  required.

### SMTP DSN and integration binding

- `handlers/callbacks.rs` now has JSON callback routes, an SMTP DSN route and an
  integration-id SMTP route.
- SMTP requires `multipart/report; report-type=delivery-status`, a non-empty
  `x-gurine-mta-assertion`, normalizes one delivery item, and records
  `acceptSmtpDsn` with `GURINE_MTA_ASSERTION`.
- `load_revision` verifies `pc.integration_id`, channel, webhook secret
  reference, config/preflight revision and activation state.  This closes the
  prior discarded-integration-id issue.

### Credential revision binding

`provider_revision_is_current` now compares the environment's
`COMMUNICATION_<CHANNEL>_TOKEN_SECRET_REFERENCE` to the immutable DB
`credential_secret_reference` and checks the approved provider/preflight
revision before endpoint/token lookup.  A live production DB/secret resolver
readback is still absent, so this is static/runtime-partial evidence rather
than a complete credential proof.

### Multimodal artifact evidence

`implementation-evidence/media-runtime/runtime-evidence.json` records:

- FFmpeg `93a42a...a4ff`, ffprobe `f0ea80...63d8`, whisper executable
  `8ab140...95d8`, and model digest
  `1fc70f...2bc69`;
- builder image and final OCI digest
  `sha256:d7ee101394084fda0bf9b4600ed44b4498787fe7e0a4a97e495a1c87bb18290e`.

The hashes match the evidence binaries and the running image ID.  The SPDX
and scan receipts are non-null and the scan result is `PASS`; the final image
contains Poppler 25.06.0 and Tesseract 5.5.0.

### Process lifecycle

`common.rs` now creates isolated process groups, drains stdout on a reader
thread with a bounded timeout, and terminates groups through the `/bin/sh`
`kill` builtin; the shell syntax was corrected to avoid dash's unsupported
`--` form.  The recorded final OCI image predates these latest source changes,
so the process contract still requires a rebuilt image and timeout/output-limit
runtime evidence before it can pass.

### Golden test

`cargo test -p gurine-document-extractor --locked` runs four multimodal tests
successfully but fails `authority_parser_golden_cases_match_exactly` with
`PROCESS_START_FAILED` because the host has no Poppler/Tesseract executables.
The final image contains the pinned parser tools, but an unchanged-source
golden test run inside the final image (or equivalent reproducible test image)
has not been produced as evidence.

Communication tests pass:

```text
cargo test -p gurine-notification-worker -p gurine-egress-gateway --locked
  5 passed
rustfmt --edition 2024 --check services/document-extractor/src/common.rs
cargo clippy -p gurine-document-extractor -p gurine-egress-gateway -p gurine-notification-worker --locked -- -D warnings
  PASS
```

## Required before LGTM

1. Rebuild the final OCI image from the current process-lifecycle source and
   run timeout/output-limit/group-reap cases for FFmpeg, ffprobe and OCR (plus
   whisper), preserving evidence bound to the new digest.
2. Run the unchanged-source 15-case golden corpus in the pinned
   document-extractor test/runtime image and preserve PASS evidence bound to
   the final OCI digest.
3. Add live DB/secret-resolver evidence proving the credential reference and
   actual provider token are the same approved revision.

Until all three items have current evidence, `LGTM_NO_BLOCKING` and
`ARTIFACT_READY` are forbidden.
