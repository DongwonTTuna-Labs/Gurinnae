use serde_json::json;
use sqlx::PgPool;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::scheduler::SchedulerError;

const SYNC_INTERVAL_SECONDS: i64 = 6 * 60 * 60;

#[derive(Clone, Debug, Eq, PartialEq)]
struct SyncSlot {
    scheduled_bucket: OffsetDateTime,
    scheduled_bucket_rfc3339: String,
    dedupe_key: String,
}

impl SyncSlot {
    fn for_instant(now: OffsetDateTime) -> Result<Self, SchedulerError> {
        let bucket_timestamp = now
            .unix_timestamp()
            .div_euclid(SYNC_INTERVAL_SECONDS)
            .checked_mul(SYNC_INTERVAL_SECONDS)
            .ok_or(SchedulerError::Initialization)?;
        let scheduled_bucket = OffsetDateTime::from_unix_timestamp(bucket_timestamp)
            .map_err(|_| SchedulerError::Initialization)?;
        let scheduled_bucket_rfc3339 = scheduled_bucket
            .format(&Rfc3339)
            .map_err(|_| SchedulerError::Initialization)?;
        let dedupe_key = format!("relay-model-catalog-sync:{scheduled_bucket_rfc3339}");
        Ok(Self {
            scheduled_bucket,
            scheduled_bucket_rfc3339,
            dedupe_key,
        })
    }
}

pub(crate) async fn schedule_relay_model_catalog_sync(
    pool: &PgPool,
) -> Result<u64, SchedulerError> {
    let slot = SyncSlot::for_instant(OffsetDateTime::now_utc())?;
    let sync_run_id = Uuid::new_v4();
    let mut tx = pool.begin().await.map_err(SchedulerError::Database)?;
    let inserted = sqlx::query_scalar!(
        "INSERT INTO ops.relay_model_catalog_sync_runs(id,scheduled_bucket,status) \
         VALUES($1,$2,'QUEUED') ON CONFLICT(scheduled_bucket) DO NOTHING RETURNING id",
        sync_run_id,
        slot.scheduled_bucket,
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(SchedulerError::Database)?;
    if inserted.is_none() {
        tx.commit().await.map_err(SchedulerError::Database)?;
        return Ok(0);
    }
    sqlx::query!(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
         VALUES('RELAY_MODEL_CATALOG_SYNC','analysis-worker',$1,$2,8)",
        json!({
            "catalogSyncRunId": sync_run_id,
            "scheduledBucket": slot.scheduled_bucket_rfc3339,
        }),
        slot.dedupe_key,
    )
    .execute(&mut *tx)
    .await
    .map_err(SchedulerError::Database)?;
    tx.commit().await.map_err(SchedulerError::Database)?;
    tracing::info!(%sync_run_id,scheduled_bucket=%slot.scheduled_bucket,"relay model catalog sync scheduled");
    Ok(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timestamp(value: &str) -> OffsetDateTime {
        OffsetDateTime::parse(value, &Rfc3339).expect("test timestamp must be RFC 3339")
    }

    #[test]
    fn bucket_is_floored_to_six_hour_utc_boundary() {
        let slot = SyncSlot::for_instant(timestamp("2026-07-29T11:59:59.999Z"))
            .expect("valid timestamp must produce a slot");

        assert_eq!(slot.scheduled_bucket, timestamp("2026-07-29T06:00:00Z"));
        assert_eq!(slot.scheduled_bucket_rfc3339, "2026-07-29T06:00:00Z");
        assert_eq!(
            slot.dedupe_key,
            "relay-model-catalog-sync:2026-07-29T06:00:00Z"
        );
    }

    #[test]
    fn instants_in_one_bucket_share_one_schedule_identity() {
        let first = SyncSlot::for_instant(timestamp("2026-07-29T12:00:00Z"))
            .expect("valid timestamp must produce a slot");
        let duplicate = SyncSlot::for_instant(timestamp("2026-07-29T17:59:59.999Z"))
            .expect("valid timestamp must produce a slot");

        assert_eq!(first, duplicate);
    }

    #[test]
    fn next_boundary_starts_the_next_bucket() {
        let previous = SyncSlot::for_instant(timestamp("2026-07-29T17:59:59.999Z"))
            .expect("valid timestamp must produce a slot");
        let next = SyncSlot::for_instant(timestamp("2026-07-29T18:00:00Z"))
            .expect("valid timestamp must produce a slot");

        assert_eq!(previous.scheduled_bucket, timestamp("2026-07-29T12:00:00Z"));
        assert_eq!(next.scheduled_bucket, timestamp("2026-07-29T18:00:00Z"));
        assert_ne!(previous.dedupe_key, next.dedupe_key);
    }
}
