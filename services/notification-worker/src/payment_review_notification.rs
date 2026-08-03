const PAYMENT_REVIEW_REQUESTED_EVENT_TYPE: &str = "notification.payment_review_requested.v1";

#[derive(Clone, Copy, Debug, serde::Deserialize, Eq, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum PaymentReviewSourceKind {
    DonationPaymentFailure,
    SignedCollectionFailure,
}

impl PaymentReviewSourceKind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::DonationPaymentFailure => "DONATION_PAYMENT_FAILURE",
            Self::SignedCollectionFailure => "SIGNED_COLLECTION_FAILURE",
        }
    }
}

#[derive(Clone, Debug, serde::Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PaymentReviewRequestedV1 {
    #[serde(deserialize_with = "deserialize_payment_review_uuid")]
    review_task_id: Uuid,
    review_task_version: i64,
    review_task_digest: String,
    source_kind: PaymentReviewSourceKind,
    #[serde(deserialize_with = "deserialize_payment_review_uuid")]
    source_receipt_id: Uuid,
    source_receipt_digest: String,
    occurred_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PaymentReviewMaterializationReceipt {
    event_id: Uuid,
    review_task_id: Uuid,
    review_task_version: i64,
    review_task_digest: String,
    source_kind: PaymentReviewSourceKind,
    source_receipt_id: Uuid,
    source_receipt_digest: String,
    occurred_at: time::OffsetDateTime,
    intent_id: Uuid,
    intent_digest: String,
    prior_intent_version: i64,
    intent_version: i64,
    intent_state: String,
    transition_receipt_digest: String,
    audit_event_id: Option<Uuid>,
    outbox_event_id: Option<Uuid>,
    idempotency_replay: bool,
}

#[derive(sqlx::FromRow)]
struct PaymentReviewMaterializationRow {
    event_id: Uuid,
    review_task_id: Uuid,
    review_task_version: i64,
    review_task_digest: String,
    source_kind: String,
    source_receipt_id: Uuid,
    source_receipt_digest: String,
    occurred_at: time::OffsetDateTime,
    intent_id: Uuid,
    intent_digest: String,
    prior_intent_version: i64,
    intent_version: i64,
    intent_state: String,
    transition_receipt_digest: String,
    audit_event_id: Option<Uuid>,
    outbox_event_id: Option<Uuid>,
    idempotency_replay: bool,
}

fn parse_payment_review_requested_v1(
    event: &ClaimedEvent,
) -> Result<PaymentReviewRequestedV1, WorkerError> {
    if event.consumer_id != "notification-worker"
        || !payment_review_uuid_is_valid(event.id)
        || event.event_type != PAYMENT_REVIEW_REQUESTED_EVENT_TYPE
    {
        return Err(WorkerError::Contract);
    }
    let requested: PaymentReviewRequestedV1 =
        serde_json::from_value(event.payload.clone()).map_err(|_| WorkerError::Contract)?;
    if !payment_review_uuid_is_valid(requested.review_task_id)
        || requested.review_task_id != event.aggregate_id
        || !payment_review_uuid_is_valid(event.aggregate_id)
        || requested.review_task_version < 1
        || requested.review_task_version != event.aggregate_version
        || !payment_review_digest_is_valid(&requested.review_task_digest)
        || !payment_review_uuid_is_valid(requested.source_receipt_id)
        || !payment_review_digest_is_valid(&requested.source_receipt_digest)
        || payment_review_occurred_at(&requested.occurred_at).is_err()
    {
        return Err(WorkerError::Contract);
    }
    Ok(requested)
}

fn deserialize_payment_review_uuid<'de, D>(deserializer: D) -> Result<Uuid, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = <String as serde::Deserialize>::deserialize(deserializer)?;
    let parsed = Uuid::parse_str(&raw).map_err(|_| serde::de::Error::custom("invalid UUID"))?;
    if raw == parsed.hyphenated().to_string() && payment_review_uuid_is_valid(parsed) {
        Ok(parsed)
    } else {
        Err(serde::de::Error::custom("invalid canonical UUID"))
    }
}

fn payment_review_uuid_is_valid(value: Uuid) -> bool {
    let encoded = value.hyphenated().to_string();
    let bytes = encoded.as_bytes();
    matches!(bytes.get(14), Some(b'1'..=b'5'))
        && matches!(bytes.get(19), Some(b'8' | b'9' | b'a' | b'b'))
}

fn payment_review_digest_is_valid(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn payment_review_occurred_at(value: &str) -> Result<time::OffsetDateTime, WorkerError> {
    time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
        .map_err(|_| WorkerError::Contract)
}

fn validate_payment_review_materialization_receipt(
    event: &ClaimedEvent,
    requested: &PaymentReviewRequestedV1,
    receipt: &PaymentReviewMaterializationReceipt,
) -> Result<(), WorkerError> {
    let occurred_at = payment_review_occurred_at(&requested.occurred_at)?;
    let version_is_valid = if receipt.idempotency_replay {
        receipt.intent_version == receipt.prior_intent_version
            && receipt.audit_event_id.is_none()
            && receipt.outbox_event_id.is_none()
    } else {
        receipt.prior_intent_version.checked_add(1) == Some(receipt.intent_version)
            && receipt
                .audit_event_id
                .is_some_and(payment_review_uuid_is_valid)
            && receipt.outbox_event_id.is_none()
    };
    if receipt.event_id != event.id
        || receipt.review_task_id != requested.review_task_id
        || receipt.review_task_version != requested.review_task_version
        || receipt.review_task_digest != requested.review_task_digest
        || receipt.source_kind != requested.source_kind
        || receipt.source_receipt_id != requested.source_receipt_id
        || receipt.source_receipt_digest != requested.source_receipt_digest
        || receipt.occurred_at != occurred_at
        || !payment_review_uuid_is_valid(receipt.intent_id)
        || !payment_review_digest_is_valid(&receipt.intent_digest)
        || receipt.prior_intent_version < 1
        || receipt.intent_version < 1
        || receipt.intent_state != "MATERIALIZED"
        || !payment_review_digest_is_valid(&receipt.transition_receipt_digest)
        || !version_is_valid
    {
        return Err(WorkerError::Contract);
    }
    Ok(())
}

async fn process_payment_review_notification_claim(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    match process_payment_review_notification(state, job, event).await {
        Ok(()) => Ok(()),
        Err(WorkerError::Job(error)) => Err(WorkerError::Job(error)),
        Err(error) => {
            let (code, detail, retryable) = match error {
                WorkerError::Database => (
                    "PAYMENT_REVIEW_AUTHORITY_UNAVAILABLE",
                    "payment review authority could not be materialized",
                    true,
                ),
                WorkerError::Contract => (
                    "PAYMENT_REVIEW_CONTRACT_INVALID",
                    "payment review event or authority binding is invalid",
                    false,
                ),
                WorkerError::Cryptography | WorkerError::Delivery | WorkerError::Initialization => {
                    (
                        "PAYMENT_REVIEW_WORKER_INVALID",
                        "payment review worker state is invalid",
                        false,
                    )
                }
                WorkerError::Job(error) => return Err(WorkerError::Job(error)),
            };
            state
                .worker
                .fail(
                    &state.pool,
                    job,
                    code,
                    detail,
                    retryable,
                    serde_json::json!({
                        "eventId":event.id,
                        "reviewTaskId":event.aggregate_id,
                    }),
                )
                .await
                .map(|_| ())
                .map_err(WorkerError::Job)
        }
    }
}

async fn process_payment_review_notification(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let requested = parse_payment_review_requested_v1(event)?;
    let mut transaction = state
        .pool
        .begin()
        .await
        .map_err(|_| WorkerError::Database)?;
    let receipt =
        materialize_payment_review_notification(&mut transaction, event, &requested).await?;
    validate_payment_review_materialization_receipt(event, &requested, &receipt)?;

    let completed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
          WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
    )
    .bind(&event.consumer_id)
    .bind(event.id)
    .execute(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?
    .rows_affected();
    if completed != 1 {
        return Err(WorkerError::Database);
    }
    transaction
        .commit()
        .await
        .map_err(|_| WorkerError::Database)?;
    state
        .worker
        .complete(
            &state.pool,
            job,
            serde_json::json!({
                "eventId":event.id,
                "reviewTaskId":requested.review_task_id,
                "reviewTaskVersion":requested.review_task_version,
                "intentId":receipt.intent_id,
                "intentVersion":receipt.intent_version,
                "materializationReplay":receipt.idempotency_replay,
            }),
        )
        .await
        .map_err(WorkerError::Job)?;
    tracing::info!(
        event_id=%event.id,
        review_task_id=%requested.review_task_id,
        intent_id=%receipt.intent_id,
        replay=receipt.idempotency_replay,
        "payment review notification intent materialized"
    );
    Ok(())
}

async fn materialize_payment_review_notification(
    transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    event: &ClaimedEvent,
    requested: &PaymentReviewRequestedV1,
) -> Result<PaymentReviewMaterializationReceipt, WorkerError> {
    let occurred_at = payment_review_occurred_at(&requested.occurred_at)?;
    let row = sqlx::query_as::<_, PaymentReviewMaterializationRow>(
        "SELECT event_id,review_task_id,review_task_version, \
           btrim(review_task_digest::text) AS review_task_digest,source_kind, \
           source_receipt_id, \
           btrim(source_receipt_digest::text) AS source_receipt_digest, \
           occurred_at,intent_id,btrim(intent_digest::text) AS intent_digest, \
           prior_intent_version,intent_version,intent_state, \
           btrim(transition_receipt_digest::text) AS transition_receipt_digest, \
           audit_event_id,outbox_event_id,idempotency_replay \
         FROM ops.materialize_payment_review_notification_v1( \
           ROW($1::uuid,$2::uuid,$3::bigint,$4::char(64),$5::text, \
               $6::uuid,$7::char(64),$8::timestamptz) \
             ::ops.payment_review_notification_materialize_v1 \
         )",
    )
    .bind(event.id)
    .bind(requested.review_task_id)
    .bind(requested.review_task_version)
    .bind(&requested.review_task_digest)
    .bind(requested.source_kind.as_str())
    .bind(requested.source_receipt_id)
    .bind(&requested.source_receipt_digest)
    .bind(occurred_at)
    .fetch_one(&mut **transaction)
    .await
    .map_err(classify_payment_review_materializer_error)?;
    payment_review_materialization_receipt(row)
}

fn payment_review_materialization_receipt(
    row: PaymentReviewMaterializationRow,
) -> Result<PaymentReviewMaterializationReceipt, WorkerError> {
    Ok(PaymentReviewMaterializationReceipt {
        event_id: row.event_id,
        review_task_id: row.review_task_id,
        review_task_version: row.review_task_version,
        review_task_digest: row.review_task_digest,
        source_kind: parse_payment_review_source_kind(&row.source_kind)?,
        source_receipt_id: row.source_receipt_id,
        source_receipt_digest: row.source_receipt_digest,
        occurred_at: row.occurred_at,
        intent_id: row.intent_id,
        intent_digest: row.intent_digest,
        prior_intent_version: row.prior_intent_version,
        intent_version: row.intent_version,
        intent_state: row.intent_state,
        transition_receipt_digest: row.transition_receipt_digest,
        audit_event_id: row.audit_event_id,
        outbox_event_id: row.outbox_event_id,
        idempotency_replay: row.idempotency_replay,
    })
}

fn parse_payment_review_source_kind(value: &str) -> Result<PaymentReviewSourceKind, WorkerError> {
    match value {
        "DONATION_PAYMENT_FAILURE" => Ok(PaymentReviewSourceKind::DonationPaymentFailure),
        "SIGNED_COLLECTION_FAILURE" => Ok(PaymentReviewSourceKind::SignedCollectionFailure),
        _ => Err(WorkerError::Contract),
    }
}

fn classify_payment_review_materializer_error(error: sqlx::Error) -> WorkerError {
    let is_contract_error = error
        .as_database_error()
        .and_then(|database_error| database_error.code())
        .is_some_and(|code| payment_review_sqlstate_is_contract(code.as_ref()));
    if is_contract_error {
        WorkerError::Contract
    } else {
        WorkerError::Database
    }
}

fn payment_review_sqlstate_is_contract(code: &str) -> bool {
    code.starts_with("22")
        || code.starts_with("23")
        || matches!(code, "42501" | "55000" | "P0002")
}

#[cfg(test)]
include!("payment_review_notification_tests.rs");
