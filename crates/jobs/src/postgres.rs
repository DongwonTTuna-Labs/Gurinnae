use std::time::Duration;

use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};
use thiserror::Error;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::fencing::Fence;

#[derive(Clone, Debug)]
pub struct ClaimedJob {
    pub id: Uuid,
    pub job_type: String,
    pub queue: String,
    pub payload: Value,
    pub attempt: i32,
    pub max_attempts: i32,
    pub fence: Fence,
    pub lease_expires_at: OffsetDateTime,
}

#[derive(Clone, Debug)]
pub struct Worker {
    pub id: String,
    pub queue: String,
    pub lease: Duration,
}

#[derive(Debug, Error)]
pub enum JobError {
    #[error("job database operation failed")]
    Database(#[source] sqlx::Error),
    #[error("job lease is stale")]
    StaleFence,
    #[error("job configuration is invalid")]
    InvalidConfiguration,
}

pub async fn recover_expired(pool: &PgPool, limit: u32) -> Result<u64, JobError> {
    if limit == 0 || limit > 10_000 {
        return Err(JobError::InvalidConfiguration);
    }
    let mut recovered = 0_u64;
    for _ in 0..limit {
        let mut tx = pool.begin().await.map_err(JobError::Database)?;
        let row = sqlx::query(
            "SELECT id,job_type,attempt_count,max_attempts,version \
             FROM ops.jobs WHERE status='RUNNING' AND lease_expires_at<=clock_timestamp() \
             ORDER BY lease_expires_at,id FOR UPDATE SKIP LOCKED LIMIT 1",
        )
        .fetch_optional(&mut *tx)
        .await
        .map_err(JobError::Database)?;
        let Some(row) = row else {
            tx.commit().await.map_err(JobError::Database)?;
            break;
        };
        let id: Uuid = row.try_get("id").map_err(JobError::Database)?;
        let job_type: String = row.try_get("job_type").map_err(JobError::Database)?;
        let attempt: i32 = row.try_get("attempt_count").map_err(JobError::Database)?;
        let max_attempts: i32 = row.try_get("max_attempts").map_err(JobError::Database)?;
        let retry = attempt < max_attempts;
        let updated = sqlx::query(
            "UPDATE ops.jobs SET \
               status=CASE WHEN $2 THEN 'QUEUED'::ops.job_status ELSE 'DEAD_LETTER'::ops.job_status END, \
               run_after=CASE WHEN $2 THEN clock_timestamp()+make_interval(secs=>$3) ELSE run_after END, \
               completed_at=CASE WHEN $2 THEN NULL ELSE clock_timestamp() END, \
               lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL, \
               last_error_code='LEASE_EXPIRED',last_error_detail='worker lease expired before completion', \
               version=version+1 WHERE id=$1 AND status='RUNNING' \
             RETURNING version",
        )
        .bind(id)
        .bind(retry)
        .bind(retry_delay_seconds(attempt) as f64)
        .fetch_optional(&mut *tx)
        .await
        .map_err(JobError::Database)?
        .ok_or(JobError::StaleFence)?;
        let version: i64 = updated.try_get("version").map_err(JobError::Database)?;
        sqlx::query(
            "UPDATE ops.job_attempts SET finished_at=clock_timestamp(),outcome=$3, \
             error_code='LEASE_EXPIRED',error_detail='worker lease expired before completion' \
             WHERE job_id=$1 AND attempt=$2 AND finished_at IS NULL",
        )
        .bind(id)
        .bind(attempt)
        .bind(if retry { "RETRY" } else { "DEAD_LETTER" })
        .execute(&mut *tx)
        .await
        .map_err(JobError::Database)?;
        if !retry {
            sqlx::query(
                "SELECT ops.enqueue_outbox('job',$1,$2,'job.dead_lettered.v1',$3,clock_timestamp())",
            )
            .bind(id.to_string())
            .bind(version)
            .bind(json!({"error_code":"LEASE_EXPIRED","job_id":id,"job_type":job_type}))
            .fetch_one(&mut *tx)
            .await
            .map_err(JobError::Database)?;
        }
        tx.commit().await.map_err(JobError::Database)?;
        recovered += 1;
    }
    Ok(recovered)
}

impl Worker {
    pub fn new(id: String, queue: String, lease: Duration) -> Result<Self, JobError> {
        if id.trim().is_empty()
            || id.len() > 200
            || queue.trim().is_empty()
            || queue.len() > 200
            || !(Duration::from_secs(10)..=Duration::from_secs(600)).contains(&lease)
        {
            return Err(JobError::InvalidConfiguration);
        }
        Ok(Self { id, queue, lease })
    }

    pub async fn claim(&self, pool: &PgPool) -> Result<Option<ClaimedJob>, JobError> {
        let mut tx = pool.begin().await.map_err(JobError::Database)?;
        let row = sqlx::query(
            "SELECT j.id,j.job_type,j.queue,j.payload,j.attempt_count,j.max_attempts \
             FROM ops.jobs j \
             LEFT JOIN ops.queue_controls q ON q.queue_name=j.queue \
             WHERE j.queue=$1 AND j.status='QUEUED' AND j.run_after<=clock_timestamp() \
               AND COALESCE(q.state,'RUNNING')='RUNNING' \
             ORDER BY j.priority,j.created_at,j.id \
             FOR UPDATE OF j SKIP LOCKED LIMIT 1",
        )
        .bind(&self.queue)
        .fetch_optional(&mut *tx)
        .await
        .map_err(JobError::Database)?;
        let Some(row) = row else {
            tx.commit().await.map_err(JobError::Database)?;
            return Ok(None);
        };
        let id: Uuid = row.try_get("id").map_err(JobError::Database)?;
        let previous_attempt: i32 = row.try_get("attempt_count").map_err(JobError::Database)?;
        let attempt = previous_attempt
            .checked_add(1)
            .ok_or(JobError::InvalidConfiguration)?;
        let lease_token = Uuid::new_v4();
        let lease_seconds =
            i64::try_from(self.lease.as_secs()).map_err(|_| JobError::InvalidConfiguration)?;
        let claimed = sqlx::query(
            "UPDATE ops.jobs SET status='RUNNING',lease_owner=$2,lease_token=$3, \
               lease_expires_at=clock_timestamp()+make_interval(secs=>$4), \
               fencing_token=fencing_token+1,attempt_count=$5,version=version+1 \
             WHERE id=$1 AND status='QUEUED' \
             RETURNING fencing_token,lease_expires_at",
        )
        .bind(id)
        .bind(&self.id)
        .bind(lease_token)
        .bind(lease_seconds as f64)
        .bind(attempt)
        .fetch_optional(&mut *tx)
        .await
        .map_err(JobError::Database)?
        .ok_or(JobError::StaleFence)?;
        let fencing_token: i64 = claimed
            .try_get("fencing_token")
            .map_err(JobError::Database)?;
        let lease_expires_at: OffsetDateTime = claimed
            .try_get("lease_expires_at")
            .map_err(JobError::Database)?;
        sqlx::query(
            "INSERT INTO ops.job_attempts(job_id,attempt,worker_id,fencing_token,started_at) \
             VALUES($1,$2,$3,$4,clock_timestamp())",
        )
        .bind(id)
        .bind(attempt)
        .bind(&self.id)
        .bind(fencing_token)
        .execute(&mut *tx)
        .await
        .map_err(JobError::Database)?;
        tx.commit().await.map_err(JobError::Database)?;
        Ok(Some(ClaimedJob {
            id,
            job_type: row.try_get("job_type").map_err(JobError::Database)?,
            queue: row.try_get("queue").map_err(JobError::Database)?,
            payload: row.try_get("payload").map_err(JobError::Database)?,
            attempt,
            max_attempts: row.try_get("max_attempts").map_err(JobError::Database)?,
            fence: Fence {
                lease_token,
                fencing_token,
            },
            lease_expires_at,
        }))
    }

    pub async fn renew(&self, pool: &PgPool, job: &mut ClaimedJob) -> Result<(), JobError> {
        let lease_seconds =
            i64::try_from(self.lease.as_secs()).map_err(|_| JobError::InvalidConfiguration)?;
        let expires_at = sqlx::query_scalar::<_, OffsetDateTime>(
            "UPDATE ops.jobs SET lease_expires_at=clock_timestamp()+make_interval(secs=>$4) \
             WHERE id=$1 AND status='RUNNING' AND lease_token=$2 AND fencing_token=$3 \
               AND lease_owner=$5 AND lease_expires_at>clock_timestamp() \
             RETURNING lease_expires_at",
        )
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .bind(lease_seconds as f64)
        .bind(&self.id)
        .fetch_optional(pool)
        .await
        .map_err(JobError::Database)?
        .ok_or(JobError::StaleFence)?;
        job.lease_expires_at = expires_at;
        Ok(())
    }

    pub async fn complete(
        &self,
        pool: &PgPool,
        job: &ClaimedJob,
        metrics: Value,
    ) -> Result<(), JobError> {
        let mut tx = pool.begin().await.map_err(JobError::Database)?;
        require_owned(&mut tx, self, job).await?;
        let changed = sqlx::query(
            "UPDATE ops.jobs SET status='SUCCEEDED',completed_at=clock_timestamp(), \
               lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,version=version+1, \
               last_error_code=NULL,last_error_detail=NULL \
             WHERE id=$1 AND status='RUNNING' AND lease_token=$2 AND fencing_token=$3",
        )
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .execute(&mut *tx)
        .await
        .map_err(JobError::Database)?
        .rows_affected();
        if changed != 1 {
            return Err(JobError::StaleFence);
        }
        finish_attempt(&mut tx, job, "SUCCEEDED", None, None, metrics).await?;
        tx.commit().await.map_err(JobError::Database)
    }

    pub async fn fail(
        &self,
        pool: &PgPool,
        job: &ClaimedJob,
        error_code: &str,
        error_detail: &str,
        retryable: bool,
        metrics: Value,
    ) -> Result<bool, JobError> {
        if error_code.trim().is_empty() || error_code.len() > 200 || error_detail.len() > 4_000 {
            return Err(JobError::InvalidConfiguration);
        }
        let mut tx = pool.begin().await.map_err(JobError::Database)?;
        require_owned(&mut tx, self, job).await?;
        let retry = retryable && job.attempt < job.max_attempts;
        let delay = retry_delay_seconds(job.attempt);
        let row = sqlx::query(
            "UPDATE ops.jobs SET status=CASE WHEN $4 THEN 'QUEUED'::ops.job_status ELSE 'DEAD_LETTER'::ops.job_status END, \
               run_after=CASE WHEN $4 THEN clock_timestamp()+make_interval(secs=>$5) ELSE run_after END, \
               completed_at=CASE WHEN $4 THEN NULL ELSE clock_timestamp() END, \
               lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL, \
               last_error_code=$6,last_error_detail=$7,version=version+1 \
             WHERE id=$1 AND status='RUNNING' AND lease_token=$2 AND fencing_token=$3 \
             RETURNING version",
        )
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .bind(retry)
        .bind(delay as f64)
        .bind(error_code)
        .bind(error_detail)
        .fetch_optional(&mut *tx)
        .await
        .map_err(JobError::Database)?
        .ok_or(JobError::StaleFence)?;
        let version: i64 = row.try_get("version").map_err(JobError::Database)?;
        finish_attempt(
            &mut tx,
            job,
            if retry { "RETRY" } else { "DEAD_LETTER" },
            Some(error_code),
            Some(error_detail),
            metrics,
        )
        .await?;
        if !retry {
            sqlx::query("SELECT ops.enqueue_outbox('job',$1,$2,'job.dead_lettered.v1',$3,clock_timestamp())")
                .bind(job.id.to_string())
                .bind(version)
                .bind(json!({"error_code":error_code,"job_id":job.id,"job_type":job.job_type}))
                .fetch_one(&mut *tx)
                .await
                .map_err(JobError::Database)?;
        }
        tx.commit().await.map_err(JobError::Database)?;
        Ok(retry)
    }
}

async fn require_owned(
    tx: &mut Transaction<'_, Postgres>,
    worker: &Worker,
    job: &ClaimedJob,
) -> Result<(), JobError> {
    let owned = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM ops.jobs WHERE id=$1 AND status='RUNNING' \
         AND lease_owner=$2 AND lease_token=$3 AND fencing_token=$4 \
         AND lease_expires_at>clock_timestamp())",
    )
    .bind(job.id)
    .bind(&worker.id)
    .bind(job.fence.lease_token)
    .bind(job.fence.fencing_token)
    .fetch_one(&mut **tx)
    .await
    .map_err(JobError::Database)?;
    if owned {
        Ok(())
    } else {
        Err(JobError::StaleFence)
    }
}

async fn finish_attempt(
    tx: &mut Transaction<'_, Postgres>,
    job: &ClaimedJob,
    outcome: &str,
    error_code: Option<&str>,
    error_detail: Option<&str>,
    metrics: Value,
) -> Result<(), JobError> {
    let changed = sqlx::query(
        "UPDATE ops.job_attempts SET finished_at=clock_timestamp(),outcome=$3, \
         error_code=$4,error_detail=$5,metrics=$6 \
         WHERE job_id=$1 AND attempt=$2 AND finished_at IS NULL",
    )
    .bind(job.id)
    .bind(job.attempt)
    .bind(outcome)
    .bind(error_code)
    .bind(error_detail)
    .bind(metrics)
    .execute(&mut **tx)
    .await
    .map_err(JobError::Database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(JobError::StaleFence)
    }
}

fn retry_delay_seconds(attempt: i32) -> i64 {
    let exponent = u32::try_from(attempt.saturating_sub(1)).unwrap_or(0).min(8);
    (5_i64.saturating_mul(1_i64 << exponent)).min(900)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_retry_delay() {
        assert_eq!(retry_delay_seconds(1), 5);
        assert_eq!(retry_delay_seconds(2), 10);
        assert_eq!(retry_delay_seconds(20), 900);
    }
}
