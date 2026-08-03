use gurine_jobs::postgres::{ClaimedJob, Worker};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Transaction};
use time::OffsetDateTime;
use uuid::Uuid;

use super::{CONSUMER_ID, DonationFactRecordedEvent, EVENT_TYPE, Failure};

const PROJECT_QUERY: &str = r#"
SELECT
  (projected.receipt).job_id AS job_id,
  (projected.receipt).job_fencing_token AS job_fencing_token,
  (projected.receipt).event_id AS event_id,
  (projected.receipt).aggregate_root_fact_id AS aggregate_root_fact_id,
  (projected.receipt).aggregate_version AS aggregate_version,
  (projected.receipt).donation_fact_id AS donation_fact_id,
  (projected.receipt).donation_fact_digest::text AS donation_fact_digest,
  (projected.receipt).candidate_header_digest::text AS candidate_header_digest,
  (projected.receipt).candidate_entry_digest::text AS candidate_entry_digest,
  (projected.receipt).inbox_receipt_digest::text AS inbox_receipt_digest,
  (projected.receipt).job_receipt_digest::text AS job_receipt_digest,
  (projected.receipt).audit_event_digest::text AS audit_event_digest,
  (projected.receipt).receipt_digest::text AS receipt_digest,
  (projected.receipt).completed_at AS completed_at
FROM (
  SELECT ops.project_donation_fact_candidate_v1(
    ROW(
      $1::uuid,$2::uuid,$3::bigint,$4::text,$5::uuid,$6::uuid,$7::bigint,
      $8::uuid,$9::text::char(64),$10::uuid,$11::text::char(64),
      $12::text::char(64),$13::timestamptz,$14::timestamptz
    )::ops.donation_funding_candidate_projection_v1
  ) AS receipt
) AS projected
"#;

#[derive(Debug, sqlx::FromRow)]
struct DonationFundingCandidateReceipt {
    job_id: Uuid,
    job_fencing_token: i64,
    event_id: Uuid,
    aggregate_root_fact_id: Uuid,
    aggregate_version: i64,
    donation_fact_id: Uuid,
    donation_fact_digest: String,
    candidate_header_digest: String,
    candidate_entry_digest: String,
    inbox_receipt_digest: String,
    job_receipt_digest: String,
    audit_event_digest: String,
    receipt_digest: String,
    completed_at: OffsetDateTime,
}

pub(in crate::runner) async fn handle(
    pool: &PgPool,
    worker: &Worker,
    job: &ClaimedJob,
    event_id: Uuid,
) -> Result<Value, Failure> {
    let event = DonationFactRecordedEvent::parse(&job.payload, event_id)?;
    let mut transaction = pool.begin().await.map_err(database_unavailable)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *transaction)
        .await
        .map_err(candidate_database_failure)?;
    let receipt = project(&mut transaction, worker, job, &event).await?;
    validate_receipt(job, &event, &receipt)?;
    transaction
        .commit()
        .await
        .map_err(candidate_database_failure)?;
    Ok(redacted_result(&event, &receipt))
}

async fn project(
    transaction: &mut Transaction<'_, Postgres>,
    worker: &Worker,
    job: &ClaimedJob,
    event: &DonationFactRecordedEvent,
) -> Result<DonationFundingCandidateReceipt, Failure> {
    sqlx::query_as::<_, DonationFundingCandidateReceipt>(PROJECT_QUERY)
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .bind(&worker.id)
        .bind(event.event_id)
        .bind(event.aggregate_id)
        .bind(event.aggregate_version)
        .bind(event.donation_fact_id)
        .bind(&event.donation_fact_digest)
        .bind(event.charge_attempt_id)
        .bind(&event.charge_attempt_digest)
        .bind(&event.provider_fetch_digest)
        .bind(event.donation_occurred_at)
        .bind(event.event_occurred_at)
        .fetch_one(&mut **transaction)
        .await
        .map_err(candidate_database_failure)
}

fn validate_receipt(
    job: &ClaimedJob,
    event: &DonationFactRecordedEvent,
    receipt: &DonationFundingCandidateReceipt,
) -> Result<(), Failure> {
    if receipt.job_id != job.id
        || receipt.job_fencing_token != job.fence.fencing_token
        || receipt.event_id != event.event_id
        || receipt.aggregate_root_fact_id != event.aggregate_id
        || receipt.aggregate_version != event.aggregate_version
        || receipt.donation_fact_id != event.donation_fact_id
        || receipt.donation_fact_digest.trim() != event.donation_fact_digest
        || !digest(receipt.candidate_header_digest.trim())
        || !digest(receipt.candidate_entry_digest.trim())
        || !digest(receipt.inbox_receipt_digest.trim())
        || !digest(receipt.job_receipt_digest.trim())
        || !digest(receipt.audit_event_digest.trim())
        || !digest(receipt.receipt_digest.trim())
        || receipt.completed_at < event.event_occurred_at
    {
        return Err(Failure::Terminal(
            "DONATION_FUNDING_CANDIDATE_RECEIPT_INVALID",
            "owner function returned an invalid closed receipt".to_owned(),
        ));
    }
    Ok(())
}

fn redacted_result(
    event: &DonationFactRecordedEvent,
    receipt: &DonationFundingCandidateReceipt,
) -> Value {
    json!({
        "consumerId":CONSUMER_ID,
        "eventType":EVENT_TYPE,
        "aggregateVersion":event.aggregate_version,
        "candidateHeaderDigest":receipt.candidate_header_digest.trim(),
        "candidateEntryDigest":receipt.candidate_entry_digest.trim(),
        "receiptDigest":receipt.receipt_digest.trim(),
        "completedAt":receipt.completed_at,
    })
}

fn candidate_database_failure(error: sqlx::Error) -> Failure {
    let Some(database_error) = error.as_database_error() else {
        return database_unavailable(error);
    };
    let code = database_error.code();
    classify_candidate_database_failure(code.as_deref())
        .unwrap_or_else(|| database_unavailable(error))
}

fn classify_candidate_database_failure(code: Option<&str>) -> Option<Failure> {
    match code {
        Some("40001") => Some(retryable(
            "DONATION_FUNDING_CANDIDATE_RECONCILIATION_REQUIRED",
        )),
        Some("25001") => Some(terminal("DONATION_FUNDING_CANDIDATE_ISOLATION_INVALID")),
        Some("22007" | "22023" | "22P02") => {
            Some(terminal("DONATION_FUNDING_CANDIDATE_INPUT_INVALID"))
        }
        Some("23514") => Some(terminal("DONATION_FUNDING_CANDIDATE_BINDING_INVALID")),
        Some("23505") => Some(terminal("DONATION_FUNDING_CANDIDATE_REPLAY_CONFLICT")),
        Some("42501") => Some(terminal("DONATION_FUNDING_CANDIDATE_AUTHORITY_INVALID")),
        Some("55000") => Some(terminal("DONATION_FUNDING_CANDIDATE_SOURCE_INVALID")),
        _ => None,
    }
}

fn terminal(code: &'static str) -> Failure {
    Failure::Terminal(code, "donation funding candidate was rejected".to_owned())
}

fn retryable(code: &'static str) -> Failure {
    Failure::Retryable(
        code,
        "donation funding candidate requires reconciliation".to_owned(),
    )
}

fn database_unavailable(_error: sqlx::Error) -> Failure {
    Failure::Retryable(
        "DATABASE_UNAVAILABLE",
        "donation funding candidate database operation failed".to_owned(),
    )
}

fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests;
