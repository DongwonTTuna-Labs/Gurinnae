use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use super::{ClaimedJob, Failure, canonical_bytes, database, sha256};

const SNAPSHOT_EVENT: &str = "dataset.snapshot_created.v1";
const SNAPSHOT_KIND: &str = "DETECTION_DATASET";
const SNAPSHOT_PRODUCER: &str = "snapshot-producer";

pub(super) async fn ready_detection_snapshot_event(
    pool: &PgPool,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    let event = parse_event(job)?;
    let selection = validate_snapshot_authority(pool, &event).await?;
    let outcome = enqueue_snapshot_evaluation(pool, &event, &selection).await?;
    Ok(json!({
        "eventId": event.event_id,
        "snapshotId": event.snapshot_id,
        "ruleVersionId": selection.rule_version_id,
        "evaluationId": outcome.evaluation_id,
        "enqueued": outcome.enqueued,
    }))
}

async fn validate_snapshot_authority(
    pool: &PgPool,
    event: &SnapshotEvent,
) -> Result<DetectionSelection, Failure> {
    let snapshot = sqlx::query!(
        "SELECT snapshot_kind,producer_component,producer_digest,producer_generation,state, \
                selection_spec,source_watermark_sha256,member_count,snapshot_sha256, \
                terminal_receipt_sha256 \
           FROM core.dataset_snapshots WHERE id=$1",
        event.snapshot_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| snapshot_event_invalid("snapshot not found"))?;
    let snapshot_sha256 = snapshot
        .snapshot_sha256
        .as_deref()
        .map(str::trim)
        .ok_or_else(|| snapshot_event_invalid("snapshotSha256"))?;
    let terminal_receipt_sha256 = snapshot
        .terminal_receipt_sha256
        .as_deref()
        .map(str::trim)
        .ok_or_else(|| snapshot_event_invalid("terminalReceiptDigest"))?;
    if snapshot.snapshot_kind != SNAPSHOT_KIND
        || snapshot.producer_component != SNAPSHOT_PRODUCER
        || snapshot.state != "READY"
        || snapshot.producer_digest.trim() != event.producer_digest
        || snapshot.producer_generation != event.producer_generation
        || snapshot.member_count != event.member_count
        || snapshot.source_watermark_sha256.trim() != event.source_watermark_digest
        || snapshot_sha256 != event.snapshot_sha256
        || terminal_receipt_sha256 != event.terminal_receipt_digest
    {
        return Err(snapshot_event_invalid("snapshot authority mismatch"));
    }
    let selection = parse_selection(&snapshot.selection_spec)?;
    let rule = sqlx::query!(
        "SELECT rule_id,configuration,code_digest,status FROM core.rule_versions WHERE id=$1",
        selection.rule_version_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| snapshot_event_invalid("rule version not found"))?;
    let configuration_sha256 = sha256(&canonical_bytes(&rule.configuration)?);
    if rule.rule_id != selection.rule_id
        || rule.code_digest.trim() != selection.rule_code_sha256
        || configuration_sha256 != selection.rule_configuration_sha256
        || rule.status != "ACTIVE"
    {
        return Err(snapshot_event_invalid("rule authority mismatch"));
    }
    Ok(selection)
}

struct SweepOutcome {
    evaluation_id: Uuid,
    enqueued: bool,
}

async fn enqueue_snapshot_evaluation(
    pool: &PgPool,
    event: &SnapshotEvent,
    selection: &DetectionSelection,
) -> Result<SweepOutcome, Failure> {
    let evaluation_id = Uuid::new_v4();
    let mut tx = pool.begin().await.map_err(database)?;
    let inserted = sqlx::query_scalar!(
        "INSERT INTO core.rule_evaluations( \
           id,rule_version_id,dataset_snapshot_id,evaluation_profile,status,requested_by,reason, \
           requester_type,requester_service) \
         VALUES($1,$2,$3,'FULL','QUEUED',NULL,$4,'SERVICE','snapshot-producer') \
         ON CONFLICT(rule_version_id,dataset_snapshot_id,evaluation_profile) DO NOTHING \
         RETURNING id",
        evaluation_id,
        selection.rule_version_id,
        event.snapshot_id,
        "automatic READY detection snapshot sweep",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?;
    let evaluation_id = match inserted {
        Some(id) => id,
        None => sqlx::query_scalar!(
            "SELECT id FROM core.rule_evaluations \
             WHERE rule_version_id=$1 AND dataset_snapshot_id=$2 AND evaluation_profile='FULL'",
            selection.rule_version_id,
            event.snapshot_id,
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(database)?,
    };
    let enqueued = sqlx::query!(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
         SELECT 'RULE_EVALUATION','analysis-worker',$2,$3,8 \
         FROM core.rule_evaluations \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING') \
         ON CONFLICT DO NOTHING",
        evaluation_id,
        json!({"evaluationId":evaluation_id}),
        evaluation_job_dedupe_key(evaluation_id),
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    mark_inbox_processed(&mut tx, event.event_id).await?;
    tx.commit().await.map_err(database)?;
    Ok(SweepOutcome {
        evaluation_id,
        enqueued: enqueued == 1,
    })
}

fn evaluation_job_dedupe_key(evaluation_id: Uuid) -> String {
    format!("rule-evaluation:{evaluation_id}")
}

async fn mark_inbox_processed(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    event_id: Uuid,
) -> Result<(), Failure> {
    let inbox_changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='analysis-worker' AND event_id=$1 AND processed_at IS NULL",
        event_id,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?
    .rows_affected();
    if inbox_changed != 1 {
        let processed = sqlx::query_scalar!(
            "SELECT processed_at IS NOT NULL AS \"processed!\" FROM ops.inbox \
             WHERE consumer='analysis-worker' AND event_id=$1",
            event_id,
        )
        .fetch_optional(&mut **tx)
        .await
        .map_err(database)?
        .unwrap_or(false);
        if !processed {
            return Err(Failure::Terminal(
                "INBOX_FENCE_FAILED",
                event_id.to_string(),
            ));
        }
    }
    Ok(())
}

struct SnapshotEvent {
    event_id: Uuid,
    snapshot_id: Uuid,
    producer_digest: String,
    producer_generation: i64,
    member_count: i64,
    source_watermark_digest: String,
    snapshot_sha256: String,
    terminal_receipt_digest: String,
}

fn parse_event(job: &ClaimedJob) -> Result<SnapshotEvent, Failure> {
    if job.job_type != "EVENT_DELIVERY"
        || job.payload.get("consumerId").and_then(Value::as_str) != Some("analysis-worker")
        || job.payload.get("eventType").and_then(Value::as_str) != Some(SNAPSHOT_EVENT)
        || job.payload.get("aggregateVersion").and_then(Value::as_i64) != Some(2)
    {
        return Err(snapshot_event_invalid("event binding"));
    }
    let payload = job
        .payload
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| snapshot_event_invalid("payload"))?;
    let event_id = event_uuid(&job.payload, "eventId")?;
    let snapshot_id = event_uuid(&Value::Object(payload.clone()), "snapshotId")?;
    if job
        .payload
        .get("aggregateId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        != Some(snapshot_id)
        || payload.get("snapshotKind").and_then(Value::as_str) != Some(SNAPSHOT_KIND)
        || payload.get("producerComponent").and_then(Value::as_str) != Some(SNAPSHOT_PRODUCER)
        || payload.get("projectionWatermark") != Some(&Value::Null)
        || payload.get("state").and_then(Value::as_str) != Some("READY")
        || payload.get("errorCode") != Some(&Value::Null)
        || payload.get("errorDigest") != Some(&Value::Null)
        || payload.get("occurredAt").and_then(Value::as_str).is_none()
    {
        return Err(snapshot_event_invalid("payload binding"));
    }
    Ok(SnapshotEvent {
        event_id,
        snapshot_id,
        producer_digest: event_hash(payload, "producerDigest")?,
        producer_generation: event_positive_i64(payload, "producerGeneration")?,
        member_count: event_nonnegative_i64(payload, "memberCount")?,
        source_watermark_digest: event_hash(payload, "sourceWatermarkDigest")?,
        snapshot_sha256: event_hash(payload, "snapshotSha256")?,
        terminal_receipt_digest: event_hash(payload, "terminalReceiptDigest")?,
    })
}

struct DetectionSelection {
    rule_id: String,
    rule_version_id: Uuid,
    rule_code_sha256: String,
    rule_configuration_sha256: String,
}

fn parse_selection(value: &Value) -> Result<DetectionSelection, Failure> {
    let object = value
        .as_object()
        .ok_or_else(|| snapshot_event_invalid("selectionSpec"))?;
    if object.get("snapshotKind").and_then(Value::as_str) != Some(SNAPSHOT_KIND)
        || object
            .get("selectionPolicyVersion")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        || object.get("cohortSpec").and_then(Value::as_array).is_none()
    {
        return Err(snapshot_event_invalid("selectionSpec"));
    }
    Ok(DetectionSelection {
        rule_id: event_string(object, "ruleId")?.to_owned(),
        rule_version_id: event_uuid(value, "ruleVersionId")?,
        rule_code_sha256: event_hash(object, "ruleCodeSha256")?,
        rule_configuration_sha256: event_hash(object, "ruleConfigurationSha256")?,
    })
}

fn event_uuid(value: &Value, key: &str) -> Result<Uuid, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| snapshot_event_invalid(key))
}

fn event_string<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &str,
) -> Result<&'a str, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| snapshot_event_invalid(key))
}

fn event_hash(object: &serde_json::Map<String, Value>, key: &str) -> Result<String, Failure> {
    let value = event_string(object, key)?;
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(snapshot_event_invalid(key));
    }
    Ok(value.to_owned())
}

fn event_positive_i64(object: &serde_json::Map<String, Value>, key: &str) -> Result<i64, Failure> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| snapshot_event_invalid(key))
}

fn event_nonnegative_i64(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<i64, Failure> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or_else(|| snapshot_event_invalid(key))
}

fn snapshot_event_invalid(detail: &str) -> Failure {
    Failure::Terminal("INVALID_DETECTION_SNAPSHOT_EVENT", detail.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detection_selection_rejects_malformed_digest() {
        let value = json!({
            "snapshotKind":"DETECTION_DATASET",
            "ruleId":"PRICE_OUTLIER",
            "ruleVersionId":Uuid::from_u128(1),
            "ruleCodeSha256":"A".repeat(64),
            "ruleConfigurationSha256":"b".repeat(64),
            "cohortSpec":[],
            "selectionPolicyVersion":"detection-selection-v1",
        });
        assert!(parse_selection(&value).is_err());
    }

    #[test]
    fn replayed_sweep_uses_the_same_evaluation_job_dedupe_key() {
        let evaluation_id = Uuid::from_u128(42);
        assert_eq!(
            evaluation_job_dedupe_key(evaluation_id),
            evaluation_job_dedupe_key(evaluation_id)
        );
        assert_ne!(
            evaluation_job_dedupe_key(evaluation_id),
            evaluation_job_dedupe_key(Uuid::from_u128(43))
        );
    }
}
