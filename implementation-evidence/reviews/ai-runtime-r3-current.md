# AI runtime / omnichannel independent review (2026-07-19, fresh source)

Authority: authority-v13 only.  This review is against the current working
tree; earlier AI-runtime review text is not treated as authority.

## Verdict

`VERDICT: CHANGES_REQUIRED`

The primary worker bridge is now present (materialize → rendering create →
approval transition → queue owner → DB rendering decrypt → provider revision
headers).  The complete hard gate still does not pass because an authenticated
provider-poll producer is absent, egress credentials are not bound to the
approved DB secret revision, and the multimodal runtime evidence remains
explicitly blocked.

## Evidence

### 1. Admission/queue owner and notification producer are present

`db/migrations/0030_v13_submission_session_hardening.sql:9793-9897`
implements `ops.queue_outbound_delivery(ops.outbound_delivery_queue_v1)` and
checks the materialized intent, approved/current rendering, endpoint snapshot,
provider activation revision, PASS preflight, budget reservation and active
suppression before inserting `ops.outbound_deliveries` and its outbox event.
The delivery-key replay and identity-conflict branches are also present.

`services/notification-worker/src/notification_intent_materialize_body.rs`
now constructs rendering/approval/queue JSON and calls the owner routines, and
`notification_typed_delivery_body.rs` resolves and decrypts the approved
rendering before claiming provider dispatch.  The queue event is therefore
reachable in the intended path.

The owner routines are now present in migration 0030.  The bridge now uses
`to_jsonb(convert_to(key,'UTF8'))`; a clean PostgreSQL check of
`jsonb_populate_record` into a `bytea` column round-trips `616263` exactly.

### 2. The event-to-dispatch contract is now connected, pending live proof

`services/notification-worker/src/notification_jobs.rs:44-55` routes the event
to `process_typed_communication_delivery`.
`services/notification-worker/src/notification_typed_delivery_body.rs` now
claims the delivery, reads the immutable rendering row, decrypts the envelope
and builds the provider request from those bytes.  This removes the earlier
missing-payload blocker, but it still needs a clean PostgreSQL/provider
integration run (including replay and terminal receipt readback).

### 3. Provider adapter path has revision fencing, with secret binding pending

`services/egress-gateway/src/handlers/mod.rs:219-278` now requires provider
config/preflight revision headers and checks those rows in PostgreSQL before
adapter dispatch.  The actual endpoint/token is still selected from
`COMMUNICATION_<CHANNEL>_URL/TOKEN`; evidence must prove that deployment
credentials correspond to the approved DB secret-reference revision rather
than only matching config/preflight headers.  The five typed adapters and
typed receipt parsers are present.

### 4. Callback gateway is executable; authenticated poll producer is absent

`ops.record_communication_callback_request` is implemented in the migration
(`0030...:9902-9974`) with provider revision/preflight checks, authentication
evidence validation, replay/conflict detection, immutable callback persistence,
acknowledgement digests and audit/outbox rows.  The egress gateway now exposes
`/private/v1/callbacks/{channel}/{integrationId}` plus the SMTP-DSN wrapper;
the handler verifies the provider signature, DB revision/preflight, encrypts
the raw request/acknowledgement and calls the owner JSON bridge.

Likewise, the notification worker can consume pre-existing
`communication.delivery_callback.v1`, `communication.delivery_poll.v1`, and
`communication.delivery_reconciliation.v1` events, but no authenticated
provider-poll/reconciliation producer creates the immutable source receipt for
`delivery_poll`.  The callback owner is reachable; status-poll providers are
still blocked.

The self-consumer hazard found in the prior review is addressed: flat
intent-materialized/rendering-created/transition payloads now reconcile as
idempotent wake-ups when no nested rendering/approval object is present.

### 5. Legacy path remains reachable

`services/notification-worker/src/notification_jobs.rs:87-178` still has a
generic delivery path that writes `ops.email_deliveries`.  It is used for the
legacy notification event classes and is not a COMMUNICATION_V1 implementation;
it must not be counted as omnichannel delivery evidence.  The file adapter is
correctly email-only (`services/notification-worker/src/handlers/delivery.rs`),
so non-email file-mode sends fail closed rather than fabricating receipts.

### 6. AI/CAS projection status

`services/control-api/src/service/query_dispatch.rs:134-168` projects provider
turns, prompt/routing policy, output validation, source-use lineage, citations,
suggestions, safety flags, human decisions and cost for CAS-011.  The static
projection is present.  This does not remedy the independent communication
owner/runtime gaps above.

### 7. Multimodal runtime support remains explicitly blocked

`specs/parsers/addendum-multimodal.yaml` is `REVIEW_REQUIRED` and declares
WAV/WebM support blocked until pinned FFmpeg/whisper.cpp runtime evidence is
complete.  The parser now verifies configured ffmpeg/ffprobe and whisper.cpp
executable/model SHA-256 values before use (`media_video_parse.rs:21-39`,
`media_asr_transcribe.rs:11-23`).  However, the `runtime_bom_additive` section
still leaves those binary hashes, exact build/configure evidence, SBOM/license
receipt and final document-extractor OCI digest null/OPEN_IMPLEMENTATION; the
VLM adapter is UNCONFIGURED and activation-gated.  The current test covers
typed rejection when the runtime is absent, not successful non-silent ASR/VLM
execution.  No WAV/WebM production-support or VLM readiness claim is valid
from the current evidence.

The subprocess wrapper also lacks the addendum's required new-process-group,
descriptor-closing and timeout/cancellation group-reap contract:
`services/document-extractor/src/media_video.rs:81-153` uses plain
`Command::spawn`, `read_to_end` and `child.kill()` on the direct child only.
This is another runtime hard gate even after binaries are installed.

## Gate matrix

| Gate | Result | Evidence |
|---|---|---|
| Telegram adapter | PARTIAL/FAIL | Typed request/receipt parser and callback ingress exist; authenticated poll/source receipt and secret binding remain open |
| WhatsApp adapter | PARTIAL/FAIL | Same |
| LINE adapter | PARTIAL/FAIL | Same |
| SOLAPI SMS | PARTIAL/FAIL | Same |
| SOLAPI Kakao | PARTIAL/FAIL | Same |
| Queue admission fences | PARTIAL | Executable bridge and producer exist; clean PostgreSQL queue/replay/readback evidence still required |
| Delivery claim/attempt fencing | PARTIAL | DB rendering decrypt and provider binding added; end-to-end provider receipt test absent |
| Provider callback/poll reconciliation | PARTIAL | Signed callback HTTP ingress is executable; authenticated status-poll source producer is absent |
| Kill-switch | PARTIAL | Egress and analysis workers read switches, but communication aggregate cannot reach them end-to-end |
| CAS-010/011 lineage projection | STATIC PASS | Query projection includes required lineage/validation/safety/human-decision fields |
| WAV/WebM pinned runtime | FAIL | Hash checks exist in code, but addendum binary/SBOM/build/OCI evidence remains OPEN/null; process-group contract is unmet |
| VLM proposal path | FAIL/NOT ACTIVATED | Provider/model/rights/preflight and source-use binding are not activated |

## Required before LGTM

1. Prove the new materialize → rendering → approval → queue bridge in a clean
   PostgreSQL runtime, including queue replay/conflict and provider receipt
   readback.  The bytea JSON bridge has been corrected and independently
   round-tripped on PostgreSQL.
2. Bind egress adapter selection and credentials to the DB-approved provider
   config/preflight/secret revision (or pass and verify an immutable activation
   receipt) before provider I/O; environment-only URL/token lookup is not
   sufficient.
3. Keep the private callback ingress for Telegram, WhatsApp, LINE, SOLAPI
   SMS/Kakao (and the configured SMTP DSN path) covered by authenticated
   normalization tests, then add an authenticated provider-poll/reconciliation
   owner for providers without a callback.  The poll owner must create an
   immutable source receipt and emit the typed delivery observation event.
4. Add live integration tests proving queue admission, claim, provider receipt,
   replay/conflict, callback acknowledgement, terminal/readback/recovery and
   kill-switch behavior for every requested channel.

## Verification run

The communication unit suites pass:

```
cargo test -p gurine-notification-worker --locked  # 1 legacy file-gateway test
cargo test -p gurine-egress-gateway --locked      # 4 typed-adapter tests
```

`cargo test -p gurine-document-extractor --locked` remains failing in this
host's authority golden corpus because an external PDF parser process cannot
start (`PROCESS_START_FAILED`); four multimodal tests pass.  The communication
tests do not exercise a clean PostgreSQL queue/receipt path or authenticated
status-poll producer, so these results cannot justify `LGTM_NO_BLOCKING`.
