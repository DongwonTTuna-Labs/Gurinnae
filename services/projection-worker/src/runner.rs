use crate::config::Config;
use agency_projection::{agency_id_from_payload, upsert_public_agency};
use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use response_submission_audit::handle_response_submitted_v2;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Transaction};
use thiserror::Error;
use uuid::Uuid;
mod addendum_projection_contract;
mod agency_projection;
mod entity_retention_anonymization;
mod response_materialized_projection;
mod response_submission_audit;
#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("projection worker initialization failed")]
    Initialization,
    #[error("projection worker job operation failed")]
    Job(#[source] JobError),
}
#[derive(Debug)]
enum Failure {
    Terminal(&'static str, String),
    Retryable(&'static str, String),
}
pub async fn run(config: Config) -> Result<(), WorkerError> {
    let pool = connect(&PoolConfig {
        database_url: config.database_url.clone(),
        max_connections: 6,
        acquire_timeout: std::time::Duration::from_secs(10),
    })
    .await
    .map_err(|_| WorkerError::Initialization)?;
    let worker = Worker::new(
        config.worker_id.clone(),
        "projection-worker".to_owned(),
        config.lease,
    )
    .map_err(WorkerError::Job)?;
    tracing::info!(worker_id=%config.worker_id,"projection worker ready");
    loop {
        let processed = process_one(&pool, &worker).await?;
        if config.once {
            if !processed {
                return Ok(());
            }
        } else if !processed {
            tokio::select! {
                () = tokio::time::sleep(config.poll_interval) => {},
                signal = tokio::signal::ctrl_c() => {
                    signal.map_err(|_| WorkerError::Initialization)?;
                    tracing::info!("projection worker shutdown requested");
                    return Ok(());
                }
            }
        }
    }
}
async fn process_one(pool: &PgPool, worker: &Worker) -> Result<bool, WorkerError> {
    let Some(job) = worker.claim(pool).await.map_err(WorkerError::Job)? else {
        return Ok(false);
    };
    match handle(pool, &job).await {
        Ok(metrics) => worker
            .complete(pool, &job, metrics)
            .await
            .map_err(WorkerError::Job)?,
        Err(Failure::Terminal(code, detail)) => {
            worker
                .fail(pool, &job, code, &detail, false, json!({}))
                .await
                .map_err(WorkerError::Job)?;
        }
        Err(Failure::Retryable(code, detail)) => {
            worker
                .fail(pool, &job, code, &detail, true, json!({}))
                .await
                .map_err(WorkerError::Job)?;
        }
    }
    Ok(true)
}
async fn handle(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    if job.job_type != "EVENT_DELIVERY" {
        return Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            job.job_type.clone(),
        ));
    }
    let event_id = parse_uuid(&job.payload, "/eventId")?;
    if entity_retention_anonymization::claims(pool, event_id, &job.payload).await? {
        return entity_retention_anonymization::handle_entity_retention_anonymized_v1(
            pool,
            event_id,
            &job.payload,
        )
        .await;
    }
    let consumer_id = job
        .payload
        .get("consumerId")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "consumerId is missing".to_owned()))?;
    if matches!(
        consumer_id,
        "audit-indexer" | "cost-projector" | "submission-projector"
    ) {
        return reconcile_addendum_projection(pool, job, event_id, consumer_id).await;
    }
    if consumer_id != "projection-worker" {
        return Err(Failure::Terminal(
            "CONSUMER_BINDING_INVALID",
            consumer_id.to_owned(),
        ));
    }
    if inbox_processed(pool, event_id).await? {
        return Ok(json!({"deduplicated":true}));
    }
    match job.payload.get("eventType").and_then(Value::as_str) {
        Some("projection.publication_revision_created.v1") => {
            let case_id = parse_uuid(&job.payload, "/payload/caseId")?;
            let snapshot_id = parse_uuid(&job.payload, "/payload/reviewSnapshotId")?;
            project_revision(pool, event_id, case_id, snapshot_id).await
        }
        Some("projection.publication_access_changed.v1") => {
            let revision_id = parse_uuid(&job.payload, "/payload/publication_id")?;
            project_access(pool, event_id, revision_id).await
        }
        _ => Err(Failure::Terminal(
            "UNSUPPORTED_EVENT_TYPE",
            "projection event type is not accepted".to_owned(),
        )),
    }
}
async fn reconcile_addendum_projection(
    pool: &PgPool,
    job: &ClaimedJob,
    event_id: Uuid,
    consumer_id: &str,
) -> Result<Value, Failure> {
    let event_type = job
        .payload
        .get("eventType")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "eventType is missing".to_owned()))?;
    if !addendum_projection_contract::event_is_accepted(consumer_id, event_type) {
        return Err(Failure::Terminal(
            "CONSUMER_EVENT_BINDING_INVALID",
            format!("{consumer_id}:{event_type}"),
        ));
    }
    verify_addendum_event_envelope(pool, job, event_id, event_type).await?;
    if consumer_id == "audit-indexer" && event_type == "response.submitted.v2" {
        return handle_response_submitted_v2(pool, event_id, &job.payload).await;
    }
    if event_type == "editorial.response_materialized.v2" {
        return response_materialized_projection::handle_response_materialized_v2(
            pool,
            event_id,
            consumer_id,
            &job.payload,
        )
        .await;
    }
    if consumer_id == "cost-projector" {
        verify_cost_receipt(pool, job).await?;
    }
    mark_addendum_inbox_processed(pool, consumer_id, event_id).await?;
    Ok(json!({"consumerId":consumer_id,"eventId":event_id,"eventType":event_type}))
}
async fn verify_addendum_event_envelope(
    pool: &PgPool,
    job: &ClaimedJob,
    event_id: Uuid,
    event_type: &str,
) -> Result<(), Failure> {
    let aggregate_id = job
        .payload
        .get("aggregateId")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "aggregateId is missing".to_owned()))?;
    let aggregate_version = job
        .payload
        .get("aggregateVersion")
        .and_then(Value::as_i64)
        .ok_or_else(|| {
            Failure::Terminal("INVALID_EVENT", "aggregateVersion is missing".to_owned())
        })?;
    let payload = job
        .payload
        .get("payload")
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "payload is missing".to_owned()))?;
    let exact: bool = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM ops.outbox WHERE id=$1 AND event_type=$2 \
           AND aggregate_id=$3 AND aggregate_version=$4 AND payload=$5) AS \"exact!\"",
        event_id,
        event_type,
        aggregate_id,
        aggregate_version,
        payload,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if !exact {
        return Err(Failure::Terminal(
            "EVENT_ENVELOPE_MISMATCH",
            event_id.to_string(),
        ));
    }
    Ok(())
}
async fn verify_cost_receipt(pool: &PgPool, job: &ClaimedJob) -> Result<(), Failure> {
    let receipt_id = parse_uuid(&job.payload, "/payload/deliveryReceiptId")?;
    let receipt_digest = job
        .payload
        .pointer("/payload/receiptDigest")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "receiptDigest is missing".to_owned()))?;
    let receipt_exists: bool = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM ops.outbound_delivery_receipts \
         WHERE id=$1 AND receipt_digest=$2) AS \"receipt_exists!\"",
        receipt_id,
        receipt_digest,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if !receipt_exists {
        return Err(Failure::Terminal(
            "DELIVERY_RECEIPT_MISMATCH",
            receipt_id.to_string(),
        ));
    }
    Ok(())
}

async fn mark_addendum_inbox_processed(
    pool: &PgPool,
    consumer_id: &str,
    event_id: Uuid,
) -> Result<(), Failure> {
    let changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
        consumer_id,
        event_id,
    )
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("STALE_INBOX", event_id.to_string()));
    }
    Ok(())
}

async fn project_revision(
    pool: &PgPool,
    event_id: Uuid,
    case_id: Uuid,
    snapshot_id: Uuid,
) -> Result<Value, Failure> {
    let revision = load_revision(pool, case_id, snapshot_id).await?;
    persist_revision(pool, event_id, case_id, &revision).await?;
    tracing::info!(
        publication_revision_id=%revision.id,
        case_id=%case_id,
        revision=revision.revision,
        "publication projected"
    );
    Ok(json!({
        "caseId":case_id,
        "revision":revision.revision,
        "publicPayloadSha256":revision.digest
    }))
}

struct RevisionProjection {
    id: Uuid,
    revision: i32,
    state: String,
    payload: Value,
    digest: String,
    slug: Option<String>,
    title: String,
    summary: Option<String>,
    published_at: time::OffsetDateTime,
    supersedes: Option<i32>,
    source_freshness: Value,
}

async fn load_revision(
    pool: &PgPool,
    case_id: Uuid,
    snapshot_id: Uuid,
) -> Result<RevisionProjection, Failure> {
    let row = sqlx::query!(
        "SELECT r.id,r.revision,r.state::text AS \"state!\",r.public_payload,r.public_payload_sha256,          r.preview_sha256,r.published_at,r.supersedes_revision,c.public_slug,c.title,c.summary          FROM editorial.publication_revisions r JOIN editorial.cases c ON c.id=r.case_id          WHERE r.case_id=$1 AND r.review_snapshot_id=$2 ORDER BY r.revision DESC LIMIT 1",
        case_id,
        snapshot_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Terminal(
            "PUBLICATION_REVISION_NOT_FOUND",
            format!("case={case_id} snapshot={snapshot_id}"),
        )
    })?;
    let digest = row.public_payload_sha256.trim().to_owned();
    let id = row.id;
    let payload = verified_revision_payload(row.public_payload, &digest, id)?;
    let source_freshness = payload
        .get("sourceFreshness")
        .or_else(|| payload.get("source_freshness"))
        .cloned()
        .unwrap_or_else(|| json!({}));
    Ok(RevisionProjection {
        id,
        revision: row.revision,
        state: row.state,
        payload,
        digest,
        slug: row.public_slug,
        title: row.title,
        summary: row.summary,
        published_at: row.published_at,
        supersedes: row.supersedes_revision,
        source_freshness,
    })
}

fn verified_revision_payload(
    payload: Value,
    expected_digest: &str,
    revision_id: Uuid,
) -> Result<Value, Failure> {
    let canonical = serde_json::to_vec(&payload)
        .map_err(|error| Failure::Terminal("PUBLIC_PAYLOAD_INVALID", error.to_string()))?;
    if sha256(&canonical) != expected_digest {
        return Err(Failure::Terminal(
            "PUBLIC_PAYLOAD_DIGEST_MISMATCH",
            revision_id.to_string(),
        ));
    }
    Ok(payload)
}

async fn persist_revision(
    pool: &PgPool,
    event_id: Uuid,
    case_id: Uuid,
    revision: &RevisionProjection,
) -> Result<(), Failure> {
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!(
        "INSERT INTO public.cases(id,slug,title,public_state,latest_revision,summary,          published_at,updated_at,source_freshness)          VALUES($1,$2,$3,$4::editorial.publication_state,$5,$6,$7,clock_timestamp(),$8)          ON CONFLICT(id) DO UPDATE SET slug=EXCLUDED.slug,title=EXCLUDED.title,          public_state=EXCLUDED.public_state,latest_revision=EXCLUDED.latest_revision,          summary=EXCLUDED.summary,published_at=LEAST(public.cases.published_at,EXCLUDED.published_at),          updated_at=clock_timestamp(),source_freshness=EXCLUDED.source_freshness",
        case_id,
        revision
            .slug
            .clone()
            .unwrap_or_else(|| format!("case-{case_id}")),
        revision
            .payload
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or(&revision.title),
        &revision.state as _,
        revision.revision,
        revision
            .payload
            .get("summary")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| revision.summary.clone())
            .unwrap_or_default(),
        revision.published_at,
        &revision.source_freshness,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "INSERT INTO public.case_revisions(case_id,revision,state,payload,payload_sha256,          published_at,supersedes_revision) VALUES($1,$2,$3::editorial.publication_state,$4,$5,$6,$7)          ON CONFLICT(case_id,revision) DO UPDATE SET state=EXCLUDED.state,payload=EXCLUDED.payload,          payload_sha256=EXCLUDED.payload_sha256,published_at=EXCLUDED.published_at,          supersedes_revision=EXCLUDED.supersedes_revision",
        case_id,
        revision.revision,
        &revision.state as _,
        &revision.payload,
        &revision.digest,
        revision.published_at,
        revision.supersedes,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    if let Some(agency_id) = agency_id_from_payload(&revision.payload) {
        upsert_public_agency(&mut tx, agency_id).await?;
    }
    sqlx::query!(
        "SELECT ops.enqueue_outbox('publication_revision',$1,$2,          'projection.publication_applied.v1',$3,clock_timestamp())",
        revision.id.to_string(),
        i64::from(revision.revision),
        json!({
            "public_payload_sha256":revision.digest,
            "publication_revision_id":revision.id
        }),
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    update_inbox(&mut tx, event_id).await?;
    tx.commit().await.map_err(database)
}
async fn project_access(
    pool: &PgPool,
    event_id: Uuid,
    revision_id: Uuid,
) -> Result<Value, Failure> {
    let row = sqlx::query!(
        "SELECT r.case_id,r.revision,r.state::text AS \"state!\",r.public_payload,r.public_payload_sha256, \
         r.published_at,r.supersedes_revision,d.scope AS \"scope?\",d.affected_ids AS \"affected_ids?\",d.expires_at AS \"expires_at?\" \
         FROM editorial.publication_revisions r \
         LEFT JOIN LATERAL (SELECT scope,affected_ids,expires_at \
           FROM editorial.publication_access_decisions d \
           WHERE d.publication_revision_id=r.id AND d.state='ACTIVE' AND d.expires_at>clock_timestamp() \
           ORDER BY d.placed_at DESC LIMIT 1) d ON true WHERE r.id=$1",
        revision_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("PUBLICATION_REVISION_NOT_FOUND", revision_id.to_string()))?;
    let case_id = row.case_id;
    let revision = row.revision;
    let state = row.state;
    let mut payload = row.public_payload;
    let scope = row.scope;
    let affected = row.affected_ids;
    let restricted = scope.is_some();
    if let Some(scope) = scope.as_deref() {
        apply_restriction(&mut payload, scope, affected.as_ref());
    }
    let digest = sha256(
        &serde_json::to_vec(&payload)
            .map_err(|error| Failure::Terminal("PUBLIC_PAYLOAD_INVALID", error.to_string()))?,
    );
    let published_at = row.published_at;
    let supersedes = row.supersedes_revision;
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!(
        "UPDATE public.cases SET public_state=$2,updated_at=clock_timestamp() WHERE id=$1",
        case_id,
        if restricted {
            "TEMPORARILY_RESTRICTED"
        } else {
            &state
        },
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "INSERT INTO public.case_revisions(case_id,revision,state,payload,payload_sha256,published_at, \
         supersedes_revision) VALUES($1,$2,$3::editorial.publication_state,$4,$5,$6,$7) \
         ON CONFLICT(case_id,revision) DO UPDATE SET payload=EXCLUDED.payload, \
         payload_sha256=EXCLUDED.payload_sha256",
        case_id,
        revision,
        &state as _,
        &payload,
        &digest,
        published_at,
        supersedes,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    update_inbox(&mut tx, event_id).await?;
    tx.commit().await.map_err(database)?;
    tracing::info!(publication_revision_id=%revision_id,restricted,"publication access projected");
    Ok(json!({"publicationRevisionId":revision_id,"restricted":restricted,"scope":scope}))
}

fn apply_restriction(payload: &mut Value, scope: &str, affected: Option<&Value>) {
    let Some(object) = payload.as_object_mut() else {
        *payload = json!({"temporarilyRestricted":true,"scope":scope});
        return;
    };
    match scope {
        "FULL" => {
            object.clear();
        }
        "CLAIMS" => restrict_collection(object, "claims", affected),
        "EVIDENCE" => restrict_collection(object, "evidence", affected),
        _ => {}
    }
    object.insert("temporarilyRestricted".to_owned(), Value::Bool(true));
    object.insert(
        "restrictionScope".to_owned(),
        Value::String(scope.to_owned()),
    );
}

fn restrict_collection(object: &mut Map<String, Value>, key: &str, affected: Option<&Value>) {
    let affected = affected
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .collect::<std::collections::BTreeSet<_>>()
        })
        .unwrap_or_default();
    if affected.is_empty() {
        object.remove(key);
    } else if let Some(items) = object.get_mut(key).and_then(Value::as_array_mut) {
        items.retain(|item| {
            item.get("id")
                .and_then(Value::as_str)
                .is_none_or(|id| !affected.contains(id))
        });
    }
}

async fn inbox_processed(pool: &PgPool, event_id: Uuid) -> Result<bool, Failure> {
    sqlx::query_scalar!(
        "SELECT processed_at IS NOT NULL AS \"processed!\" FROM ops.inbox WHERE consumer='projection-worker' AND event_id=$1",
        event_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))
}

async fn update_inbox(tx: &mut Transaction<'_, Postgres>, event_id: Uuid) -> Result<(), Failure> {
    let changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='projection-worker' AND event_id=$1 AND processed_at IS NULL",
        event_id,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal("STALE_INBOX", event_id.to_string()))
    }
}

fn parse_uuid(value: &Value, pointer: &str) -> Result<Uuid, Failure> {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                format!("{pointer} is missing or invalid"),
            )
        })
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}

#[cfg(test)]
mod tests;
