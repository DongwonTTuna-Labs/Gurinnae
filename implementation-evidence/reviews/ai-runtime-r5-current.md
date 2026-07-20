# AI runtime / omnichannel independent review (2026-07-19, frozen source)

Authority: authority-v13 only. This is a fresh review of the current source
tree and current runtime evidence; earlier AI-runtime verdicts are stale.

## Verdict

```text
VERDICT: CHANGES_REQUIRED
```

The provider poll producer/source-receipt path, authenticated callbacks,
SMTP DSN integration binding, pinned multimodal artifact record, parser golden
corpus, and credential resolver database readback are present and verified.
One hard gate remains open: no current runtime evidence demonstrates timeout,
output-limit, and process-group reap behavior for every FFmpeg/ffprobe/OCR/
whisper invocation against the final OCI digest.

## Current evidence

- `docker image inspect gurine-document-extractor:final` reports
  `sha256:854b218d2ba8a357888a79f2f65d7d66eb21075279e82aee286f21cf8668337b`,
  matching `implementation-evidence/media-runtime/runtime-evidence.json`.
- The unchanged-source `document-extractor-test` Docker target completed with
  all five tests passing, including
  `authority_parser_golden_cases_match_exactly` (15 fixtures, 0 failures),
  with Poppler 25.06.0 and Tesseract 5.5.0 runtime checks passing.
- `implementation-evidence/credential-resolver-runtime.json` is PASS from the
  live PostgreSQL resolver probe. It records a version-pinned
  `vault://test/telegram-token@v20260719` row, mutable-alias/plaintext rejection,
  matching resolver source marker, mismatch rejection, and no raw-token
  persistence/logging.
- Source review confirms scheduler emits deduplicated SMS/Kakao provider-poll
  requests; notification-worker records immutable provider-poll source
  receipts; callback routes enforce integration/config/preflight revision
  binding; and `credential_resolver.rs` fails closed when the source marker or
  token is missing/mismatched.
- Communication tests, scheduler tests, clippy, and rustfmt checks remain
  passing as recorded by the prior fresh review.

## Required before LGTM

Produce current, digest-bound runtime evidence that intentionally exercises
each media/OCR child command's timeout and output-limit paths and verifies the
entire process group is reaped (FFmpeg, ffprobe, Tesseract/OCR, and whisper).
Static source inspection, unit tests that do not exercise these paths, image
presence, and the parser golden-corpus PASS are insufficient for this hard gate.

Until that evidence is attached to the current final OCI digest, this review
must remain `VERDICT: CHANGES_REQUIRED`; `LGTM_NO_BLOCKING` and
`ARTIFACT_READY` are forbidden.
