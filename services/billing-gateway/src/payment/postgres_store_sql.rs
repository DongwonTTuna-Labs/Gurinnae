pub(super) const INTENT_CLAIM_SQL: &str = r#"
WITH r AS (SELECT ops.claim_r6e_donation_intent_v1(ROW(
 $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16
)::ops.r6e_donation_intent_claim_v1) AS v)
SELECT (v).disposition,(v).request_id,(v).donation_intent_id,(v).binding_id,
 (v).job_id,(v).amount_whole_krw,
 btrim((v).provider_issue_idempotency_key_hmac) AS provider_idempotency_hmac,
 (v).provider_issue_idempotency_hmac_key_version AS provider_idempotency_version,
 btrim((v).claim_digest) AS claim_digest,
 btrim((v).queued_receipt_digest) AS queued_receipt_digest FROM r"#;

pub(super) const BINDING_COMPLETE_SQL: &str = r#"
WITH r AS (SELECT ops.complete_r6e_payment_method_binding_v1(ROW(
 $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15
)::ops.r6e_payment_method_binding_complete_v1) AS v)
SELECT (v).disposition,(v).request_id,(v).job_id,(v).status,
 btrim((v).queued_receipt_digest) AS queued_receipt_digest FROM r"#;

pub(super) const INTENT_FAIL_SQL: &str = r#"
WITH r AS (SELECT ops.fail_r6e_donation_intent_v1(ROW(
 $1,$2,$3,$4,$5,$6,$7
)::ops.r6e_donation_intent_fail_v1) AS v)
SELECT (v).disposition,(v).state FROM r"#;

pub(super) const JOB_CLAIM_SQL: &str = r#"
WITH r AS (SELECT ops.claim_r6e_donation_charge_job_v1(ROW(
 $1,$2
)::ops.r6e_donation_charge_job_claim_v1) AS v)
SELECT (v).disposition,(v).job_id,(v).job_type,(v).queue,(v).payload,
 (v).provider,(v).amount_whole_krw,(v).attempt,(v).max_attempts,
 (v).lease_token,(v).fencing_token,(v).lease_expires_at,
 btrim((v).job_binding_digest) AS job_binding_digest FROM r"#;

pub(super) const CHARGE_CLAIM_SQL: &str = r#"
WITH r AS (SELECT ops.claim_r6e_donation_charge_v1(ROW(
 $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
)::ops.r6e_donation_charge_claim_v1) AS v)
SELECT (v).disposition,(v).attempt_id,(v).attempt_state,
 (v).provider,btrim((v).provider_idempotency_key_hmac) AS provider_idempotency_hmac,
 (v).provider_idempotency_hmac_key_version AS provider_idempotency_version,
 btrim((v).merchant_order_id_hmac) AS merchant_order_hmac,
 (v).merchant_order_hmac_key_version AS merchant_order_version,
 btrim((v).merchant_order_id_digest) AS merchant_order_digest,
 btrim((v).expected_provider_payment_id_digest) AS expected_provider_payment_digest,
 (v).amount_whole_krw,(v).credential_use_policy,(v).billing_key_secret_reference,
 btrim((v).billing_key_hmac) AS billing_key_hmac,
 (v).billing_key_hmac_key_version AS billing_key_version,
 (v).payment_method_binding_root_id AS binding_root_id,(v).logical_charge_id,
 btrim((v).job_binding_digest) AS job_binding_digest,
 btrim((v).claim_digest) AS claim_digest FROM r"#;

pub(super) const CHARGE_ACCEPT_SQL: &str = r#"
WITH r AS (SELECT ops.accept_r6e_donation_charge_v1(ROW(
 $1,$2,$3,$4,$5,$6,$7,$8
)::ops.r6e_donation_charge_accept_v1) AS v)
SELECT (v).disposition,(v).state FROM r"#;

pub(super) const CHARGE_COMPLETE_SQL: &str = r#"
WITH r AS (SELECT ops.complete_r6e_donation_charge_v1(ROW(
 $1,$2,ROW($3,$4,$5,$1,$6,$7,$8,$9,$10,$11,$12,$13)
 ::ops.r6e_payment_observation_v1,$14
)::ops.r6e_donation_charge_complete_v1) AS v)
SELECT (v).disposition,(v).attempt_id,(v).state,(v).terminal_authority,
 btrim((v).receipt_digest) AS receipt_digest,(v).fixture_authority,
 btrim((v).test_payment_outcome_config_digest) AS outcome_config_digest,(v).effects,
 (v).donation_fact_id,(v).donation_fact_effect,
 btrim((v).donation_fact_digest) AS donation_fact_digest,
 btrim((v).charge_attempt_digest) AS charge_attempt_digest,
 btrim((v).provider_fetch_digest) AS provider_fetch_digest,
 (v).donation_occurred_at,(v).donation_outbox_event_id,(v).review_task_id,
 (v).review_task_version,btrim((v).review_task_digest) AS review_task_digest,
 (v).review_source_kind,(v).review_source_receipt_id,
 btrim((v).review_source_receipt_digest) AS review_source_receipt_digest,
 (v).review_occurred_at FROM r"#;

pub(super) const CHARGE_FAIL_SQL: &str = r#"
WITH r AS (SELECT ops.fail_r6e_donation_charge_v1(ROW(
 $1,$2,$3,$4,$5
)::ops.r6e_donation_charge_fail_v1) AS v)
SELECT (v).disposition,(v).attempt_id,(v).state,(v).terminal_authority,
 btrim((v).receipt_digest) AS receipt_digest,(v).fixture_authority,
 btrim((v).test_payment_outcome_config_digest) AS outcome_config_digest,(v).effects,
 (v).donation_fact_id,(v).donation_fact_effect,btrim((v).donation_fact_digest) AS donation_fact_digest,
 btrim((v).charge_attempt_digest) AS charge_attempt_digest,
 btrim((v).provider_fetch_digest) AS provider_fetch_digest,(v).donation_occurred_at,
 (v).donation_outbox_event_id,(v).review_task_id,(v).review_task_version,
 btrim((v).review_task_digest) AS review_task_digest,(v).review_source_kind,
 (v).review_source_receipt_id,btrim((v).review_source_receipt_digest) AS review_source_receipt_digest,
 (v).review_occurred_at FROM r"#;

pub(super) const CHARGE_RECONCILE_SQL: &str = r#"
WITH r AS (SELECT ops.require_r6e_charge_reconciliation_v1(ROW(
 $1,$2,$3,$4
)::ops.r6e_charge_reconciliation_v1) AS v)
SELECT (v).disposition,(v).state FROM r"#;

pub(super) const WEBHOOK_CLAIM_SQL: &str = r#"
WITH r AS (SELECT ops.claim_r6e_provider_webhook_v1(ROW(
 $1,$2,$3,$4,$5,$6,$7,$8,$9,$10
)::ops.r6e_provider_webhook_claim_v1) AS v)
SELECT (v).disposition,(v).provider,
 btrim((v).event_identity_digest) AS event_identity_digest,
 (v).claim_id,btrim((v).claim_digest) AS claim_digest,
 (v).attempt_id,(v).logical_charge_id,btrim((v).job_binding_digest) AS job_binding_digest,
 btrim((v).charge_idempotency_key_sha256) AS charge_idempotency_digest,
 btrim((v).merchant_order_id_digest) AS merchant_order_digest,
 (v).amount_whole_krw,btrim((v).webhook_receipt_digest) AS webhook_receipt_digest FROM r"#;

pub(super) const WEBHOOK_COMPLETE_SQL: &str = r#"
WITH r AS (SELECT ops.complete_r6e_provider_webhook_v1(ROW(
 $1,$2,$3,$4,ROW($1,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
 ::ops.r6e_payment_observation_v1,$16
)::ops.r6e_provider_webhook_complete_v1) AS v)
SELECT (v).disposition,(v).provider,
 btrim((v).event_identity_digest) AS event_identity_digest,
 btrim((v).receipt_digest) AS receipt_digest FROM r"#;

pub(super) const WEBHOOK_RELEASE_SQL: &str = r#"
WITH r AS (SELECT ops.release_r6e_provider_webhook_claim_v1(ROW(
 $1,$2,$3,$4,$5,$6
)::ops.r6e_provider_webhook_release_v1) AS v)
SELECT (v).disposition,(v).state FROM r"#;

#[cfg(test)]
pub(super) const OWNER_SQL: [&str; 12] = [
    INTENT_CLAIM_SQL,
    BINDING_COMPLETE_SQL,
    INTENT_FAIL_SQL,
    JOB_CLAIM_SQL,
    CHARGE_CLAIM_SQL,
    CHARGE_ACCEPT_SQL,
    CHARGE_COMPLETE_SQL,
    CHARGE_FAIL_SQL,
    CHARGE_RECONCILE_SQL,
    WEBHOOK_CLAIM_SQL,
    WEBHOOK_COMPLETE_SQL,
    WEBHOOK_RELEASE_SQL,
];
