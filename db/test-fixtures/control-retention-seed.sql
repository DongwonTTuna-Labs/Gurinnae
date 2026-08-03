-- Deterministic read witness for the v13 retention-request workspace query.
-- This is an immutable decision row in REVIEW, so the API exercises the real
-- owner projection without fabricating a response in the control-flow test.
BEGIN;

INSERT INTO ops.retention_requests(
  id, subject_type, subject_ref_hash, request_type, status,
  legal_hold_blocked, reason, created_at
)
VALUES(
  '782e0381-42fa-5626-87dd-5405d537c951',
  'CONTROL_FIXTURE', repeat('a', 64), 'ACCESS', 'REVIEW', false,
  'Control retention fixture', clock_timestamp() - interval '2 minutes'
)
ON CONFLICT DO NOTHING;

-- Separate untouched request used by the command transition witness.  The
-- detail query above intentionally points at the decision-backed request;
-- this row exercises the RECEIVED -> REVIEW owner transition.
INSERT INTO ops.retention_requests(
  id, subject_type, subject_ref_hash, request_type, status,
  legal_hold_blocked, reason, created_at
)
VALUES(
  '983f6129-b8a3-5f12-9fed-9b668f4b266b',
  'CONTROL_TRANSITION_FIXTURE', repeat('b', 64), 'ACCESS', 'RECEIVED', false,
  'Control retention transition fixture', clock_timestamp() - interval '1 minute'
)
ON CONFLICT DO NOTHING;

INSERT INTO ops.retention_request_decisions(
  id, retention_request_id, request_type, decision_version, prior_decision_id,
  prior_state, state, transition_kind, inventory_snapshot_digest,
  hold_coverage_digest, restore_suppression_required, policy_digest,
  reason_code, reason_encrypted, reason_digest, decided_by_user_id,
  step_up_authorization_id, step_up_authorization_receipt_digest,
  step_up_issued_at, step_up_expires_at, action_digest,
  idempotency_key_sha256, actor_assertion_jti, request_id, audit_event_id,
  decision_digest, receipt_digest, decided_at
)
VALUES(
  'd8f31b65-1b31-5c85-8e3c-0bc3a9192c11',
  '782e0381-42fa-5626-87dd-5405d537c951',
  'ACCESS', 1, NULL,
  'RECEIVED', 'REVIEW', 'START_REVIEW',
  repeat('1', 64), repeat('2', 64), false, repeat('3', 64),
  'CONTROL_FIXTURE', convert_to('control retention fixture', 'UTF8'), repeat('4', 64),
  '11111111-1111-4111-8111-111111111111',
  '6a9cc1e8-94b7-5f59-8f59-ef8f2d52f233', repeat('5', 64),
  clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 hour',
  repeat('6', 64), repeat('7', 64),
  '7f5f9b2e-09d7-5bb4-9f10-7c9d2e7a8b55',
  '0c2d7ef4-f3c9-5da3-a6d3-3c7c3bdf65e2',
  'b6d28b1b-e0d0-5d74-8f6f-5a1e9c28f9cb',
  repeat('8', 64), repeat('9', 64), clock_timestamp()
)
ON CONFLICT DO NOTHING;

COMMIT;
