use sqlx::{PgPool, Row};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LeasedJob {
    pub id: Uuid,
    pub job_type: String,
    pub fencing_token: i64,
    pub lease_token: Uuid,
}

pub async fn lease_next(
    pool: &PgPool,
    queue: &str,
    worker_id: &str,
    lease_seconds: i32,
) -> Result<Option<LeasedJob>, sqlx::Error> {
    let row = sqlx::query(
        "WITH candidate AS ( \
           SELECT id FROM ops.jobs \
           WHERE queue = $1 AND status = 'QUEUED' AND run_after <= clock_timestamp() \
           ORDER BY priority, created_at FOR UPDATE SKIP LOCKED LIMIT 1 \
         ) \
         UPDATE ops.jobs AS job SET \
           status = 'LEASED', lease_owner = $2, lease_token = gen_random_uuid(), \
           lease_expires_at = clock_timestamp() + make_interval(secs => $3), \
           fencing_token = job.fencing_token + 1 \
         FROM candidate WHERE job.id = candidate.id \
         RETURNING job.id, job.job_type, job.fencing_token, job.lease_token",
    )
    .bind(queue)
    .bind(worker_id)
    .bind(lease_seconds)
    .fetch_optional(pool)
    .await?;
    row.map(|record| {
        Ok(LeasedJob {
            id: record.try_get("id")?,
            job_type: record.try_get("job_type")?,
            fencing_token: record.try_get("fencing_token")?,
            lease_token: record.try_get("lease_token")?,
        })
    })
    .transpose()
}
