use gurine_jobs::postgres::ClaimedJob;
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Transaction};
use time::OffsetDateTime;
use uuid::Uuid;

use super::{CONSUMER_ID, EVENT_TYPE, Failure, FundingDisclosurePublishedEvent};

const OPERATION_ID: &str = "ECONOMICS.PROJECT_FUNDING_DISCLOSURE.V2";
// The frozen 0029 contract does not define an executable canonical framing for
// the funding disclosure digest preimages.  Keep the mutation path closed until
// that ABI is approved and the database reader/projector are validated against
// the same authority.
const FUNDING_DIGEST_ABI_READY: bool = false;
const PROJECT_QUERY: &str = r#"
SELECT
  (projected.receipt).operation_id AS operation_id,
  (projected.receipt).event_id AS event_id,
  (projected.receipt).source_aggregate_id AS source_aggregate_id,
  (projected.receipt).source_aggregate_version AS source_aggregate_version,
  (projected.receipt).source_aggregate_digest::text AS source_aggregate_digest,
  (projected.receipt).projection_id AS projection_id,
  (projected.receipt).projection_version AS projection_version,
  (projected.receipt).projection_digest::text AS projection_digest,
  (projected.receipt).projected_row_count AS projected_row_count,
  (projected.receipt).inbox_receipt_digest::text AS inbox_receipt_digest,
  (projected.receipt).job_receipt_digest::text AS job_receipt_digest,
  (projected.receipt).audit_event_id AS audit_event_id,
  (projected.receipt).outbox_event_ids AS outbox_event_ids,
  (projected.receipt).receipt_digest::text AS receipt_digest,
  (projected.receipt).completed_at AS completed_at
FROM (
  SELECT public.project_funding_disclosure_revision_v2(
    ROW(
      $1::uuid,$2::uuid,$3::uuid,$4::bigint,$5::text::char(64),$6::uuid,
      $7::text::char(64),$8::text::editorial.funding_concentration_band,
      $9::text::char(64),$10::bigint,$11::timestamptz,$12::text::char(64),
      $13::uuid,$14::uuid,$15::bigint
    )::public.funding_disclosure_projection_v2
  ) AS receipt
) AS projected
"#;

#[derive(Debug, sqlx::FromRow)]
struct ProjectionMutationReceipt {
    operation_id: String,
    event_id: Uuid,
    source_aggregate_id: Uuid,
    source_aggregate_version: i64,
    source_aggregate_digest: String,
    projection_id: Uuid,
    projection_version: i64,
    projection_digest: String,
    projected_row_count: i64,
    inbox_receipt_digest: String,
    job_receipt_digest: String,
    audit_event_id: Uuid,
    outbox_event_ids: Vec<Uuid>,
    receipt_digest: String,
    completed_at: OffsetDateTime,
}

pub(in crate::runner) async fn handle(
    pool: &PgPool,
    job: &ClaimedJob,
    event_id: Uuid,
) -> Result<Value, Failure> {
    let event = FundingDisclosurePublishedEvent::parse(&job.payload, event_id)?;
    require_approved_digest_abi()?;
    let mut transaction = pool.begin().await.map_err(database_unavailable)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *transaction)
        .await
        .map_err(projection_database_failure)?;
    let receipt = project(&mut transaction, job, &event).await?;
    validate_receipt(&event, &receipt)?;
    transaction
        .commit()
        .await
        .map_err(projection_database_failure)?;
    Ok(redacted_result(&event, &receipt))
}

fn require_approved_digest_abi() -> Result<(), Failure> {
    if FUNDING_DIGEST_ABI_READY {
        Ok(())
    } else {
        Err(Failure::Retryable(
            "FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE",
            "redacted:funding-digest-abi-not-approved".to_owned(),
        ))
    }
}

async fn project(
    transaction: &mut Transaction<'_, Postgres>,
    job: &ClaimedJob,
    event: &FundingDisclosurePublishedEvent,
) -> Result<ProjectionMutationReceipt, Failure> {
    sqlx::query_as::<_, ProjectionMutationReceipt>(PROJECT_QUERY)
        .bind(event.event_id)
        .bind(event.disclosure_id)
        .bind(event.revision_id)
        .bind(event.revision)
        .bind(&event.revision_digest)
        .bind(event.snapshot_batch_id)
        .bind(&event.snapshot_digest)
        .bind(&event.concentration_band)
        .bind(&event.entry_set_digest)
        .bind(event.prior_revision)
        .bind(event.effective_at)
        .bind(&event.receipt_digest)
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .fetch_one(&mut **transaction)
        .await
        .map_err(projection_database_failure)
}

fn validate_receipt(
    event: &FundingDisclosurePublishedEvent,
    receipt: &ProjectionMutationReceipt,
) -> Result<(), Failure> {
    if receipt.operation_id != OPERATION_ID
        || receipt.event_id != event.event_id
        || receipt.source_aggregate_id != event.revision_id
        || receipt.source_aggregate_version != event.revision
        || receipt.source_aggregate_digest.trim() != event.revision_digest
        || receipt.projection_id.is_nil()
        || receipt.projection_version != event.revision
        || !digest(receipt.projection_digest.trim())
        || receipt.projected_row_count != 1
        || !digest(receipt.inbox_receipt_digest.trim())
        || !digest(receipt.job_receipt_digest.trim())
        || receipt.audit_event_id.is_nil()
        || !receipt.outbox_event_ids.is_empty()
        || !digest(receipt.receipt_digest.trim())
        || receipt.completed_at < event.occurred_at
    {
        return Err(Failure::Terminal(
            "FUNDING_PROJECTION_RECEIPT_INVALID",
            "owner function returned an invalid closed receipt".to_owned(),
        ));
    }
    Ok(())
}

fn redacted_result(
    event: &FundingDisclosurePublishedEvent,
    receipt: &ProjectionMutationReceipt,
) -> Value {
    json!({
        "consumerId":CONSUMER_ID,
        "eventType":EVENT_TYPE,
        "operationId":OPERATION_ID,
        "revision":event.revision,
        "projectedRowCount":receipt.projected_row_count,
        "projectionDigest":receipt.projection_digest.trim(),
        "receiptDigest":receipt.receipt_digest.trim(),
    })
}

fn projection_database_failure(error: sqlx::Error) -> Failure {
    let Some(database_error) = error.as_database_error() else {
        return database_unavailable(error);
    };
    let code = database_error.code();
    let message = database_error.message();
    classify_projection_database_failure(code.as_deref(), message)
        .unwrap_or_else(|| database_unavailable(error))
}

fn classify_projection_database_failure(code: Option<&str>, message: &str) -> Option<Failure> {
    match (code, message) {
        (Some("40001"), _) => Some(retryable("FUNDING_PROJECTION_STALE_FENCE")),
        (Some("25001"), _) => Some(terminal("FUNDING_PROJECTION_ISOLATION_INVALID")),
        (Some("22023"), _) => Some(terminal("FUNDING_PROJECTION_INPUT_INVALID")),
        (Some("23505"), _) => Some(terminal("FUNDING_PROJECTION_REPLAY_CONFLICT")),
        (Some("P0002"), _) => Some(terminal("FUNDING_PROJECTION_SOURCE_NOT_FOUND")),
        (Some("55000"), "FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE") => {
            Some(retryable("FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE"))
        }
        (Some("55000"), "FUNDING_PROJECTION_DISCLOSURE_HELD") => {
            Some(retryable("FUNDING_PROJECTION_DISCLOSURE_HELD"))
        }
        (Some("55000"), _) => Some(terminal("FUNDING_PROJECTION_SOURCE_INVALID")),
        _ => None,
    }
}

fn terminal(code: &'static str) -> Failure {
    Failure::Terminal(code, "funding projection was rejected".to_owned())
}

fn retryable(code: &'static str) -> Failure {
    Failure::Retryable(
        code,
        "funding projection requires reconciliation".to_owned(),
    )
}

fn database_unavailable(_error: sqlx::Error) -> Failure {
    Failure::Retryable(
        "DATABASE_UNAVAILABLE",
        "funding projection database operation failed".to_owned(),
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
