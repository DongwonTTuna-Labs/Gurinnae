use std::collections::HashSet;

use serde_json::Value;
use sqlx::PgPool;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::scheduler::SchedulerError;

const MAX_ENTITY_RETENTION_ENQUEUE_LIMIT: i32 = 500;
const ENQUEUE_DUE_ENTITY_RETENTION_SQL: &str =
    "SELECT ops.enqueue_due_r6d_entity_retention_jobs_v1($1)";
const ENTITY_RETENTION_OUTCOME_CONTRACT: &str = "entity retention enqueue outcome";

#[derive(Debug, Eq, PartialEq)]
struct EntityRetentionEnqueueOutcome {
    evaluated_at: OffsetDateTime,
    enqueued_count: u64,
}

pub(crate) async fn schedule_due_entity_retention_jobs(
    pool: &PgPool,
    requested_limit: i64,
) -> Result<u64, SchedulerError> {
    let limit = bounded_entity_retention_limit(requested_limit)?;
    let value = sqlx::query_scalar::<_, Option<Value>>(ENQUEUE_DUE_ENTITY_RETENTION_SQL)
        .bind(limit)
        .fetch_one(pool)
        .await
        .map_err(SchedulerError::Database)?
        .ok_or(SchedulerError::DatabaseContract(
            ENTITY_RETENTION_OUTCOME_CONTRACT,
        ))?;
    let outcome = parse_entity_retention_enqueue_outcome(&value, limit)?;
    tracing::info!(
        evaluated_at = %outcome.evaluated_at,
        enqueued_count = outcome.enqueued_count,
        "due entity retention jobs evaluated"
    );
    Ok(outcome.enqueued_count)
}

fn bounded_entity_retention_limit(requested_limit: i64) -> Result<i32, SchedulerError> {
    if requested_limit < 1 {
        return Err(SchedulerError::Initialization);
    }
    i32::try_from(requested_limit.min(i64::from(MAX_ENTITY_RETENTION_ENQUEUE_LIMIT)))
        .map_err(|_| SchedulerError::Initialization)
}

fn parse_entity_retention_enqueue_outcome(
    value: &Value,
    limit: i32,
) -> Result<EntityRetentionEnqueueOutcome, SchedulerError> {
    let object = value.as_object().ok_or(SchedulerError::DatabaseContract(
        ENTITY_RETENTION_OUTCOME_CONTRACT,
    ))?;
    if object.len() != 3
        || !object.contains_key("evaluatedAt")
        || !object.contains_key("enqueuedCount")
        || !object.contains_key("jobIds")
    {
        return Err(SchedulerError::DatabaseContract(
            ENTITY_RETENTION_OUTCOME_CONTRACT,
        ));
    }
    let evaluated_at = object
        .get("evaluatedAt")
        .and_then(Value::as_str)
        .ok_or(SchedulerError::DatabaseContract(
            ENTITY_RETENTION_OUTCOME_CONTRACT,
        ))
        .and_then(|value| {
            OffsetDateTime::parse(value, &Rfc3339)
                .map_err(|_| SchedulerError::DatabaseContract(ENTITY_RETENTION_OUTCOME_CONTRACT))
        })?;
    let enqueued_count = object.get("enqueuedCount").and_then(Value::as_u64).ok_or(
        SchedulerError::DatabaseContract(ENTITY_RETENTION_OUTCOME_CONTRACT),
    )?;
    let bounded_limit = u64::try_from(limit).map_err(|_| SchedulerError::Initialization)?;
    if enqueued_count > bounded_limit {
        return Err(SchedulerError::DatabaseContract(
            ENTITY_RETENTION_OUTCOME_CONTRACT,
        ));
    }
    let job_ids =
        object
            .get("jobIds")
            .and_then(Value::as_array)
            .ok_or(SchedulerError::DatabaseContract(
                ENTITY_RETENTION_OUTCOME_CONTRACT,
            ))?;
    let job_count = u64::try_from(job_ids.len())
        .map_err(|_| SchedulerError::DatabaseContract(ENTITY_RETENTION_OUTCOME_CONTRACT))?;
    if job_count != enqueued_count {
        return Err(SchedulerError::DatabaseContract(
            ENTITY_RETENTION_OUTCOME_CONTRACT,
        ));
    }
    let unique_job_ids = job_ids
        .iter()
        .map(parse_entity_retention_job_id)
        .collect::<Result<HashSet<_>, _>>()?;
    if unique_job_ids.len() != job_ids.len() {
        return Err(SchedulerError::DatabaseContract(
            ENTITY_RETENTION_OUTCOME_CONTRACT,
        ));
    }
    Ok(EntityRetentionEnqueueOutcome {
        evaluated_at,
        enqueued_count,
    })
}

fn parse_entity_retention_job_id(value: &Value) -> Result<Uuid, SchedulerError> {
    value
        .as_str()
        .ok_or(SchedulerError::DatabaseContract(
            ENTITY_RETENTION_OUTCOME_CONTRACT,
        ))
        .and_then(|value| {
            Uuid::parse_str(value)
                .map_err(|_| SchedulerError::DatabaseContract(ENTITY_RETENTION_OUTCOME_CONTRACT))
        })
        .and_then(|value| {
            if value.is_nil() {
                Err(SchedulerError::DatabaseContract(
                    ENTITY_RETENTION_OUTCOME_CONTRACT,
                ))
            } else {
                Ok(value)
            }
        })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn owner_call_passes_only_the_bounded_limit() {
        assert_eq!(
            ENQUEUE_DUE_ENTITY_RETENTION_SQL,
            "SELECT ops.enqueue_due_r6d_entity_retention_jobs_v1($1)"
        );
        assert!(!ENQUEUE_DUE_ENTITY_RETENTION_SQL.contains("clock_timestamp"));
        assert!(matches!(
            bounded_entity_retention_limit(0),
            Err(SchedulerError::Initialization)
        ));
        assert_eq!(bounded_entity_retention_limit(100).ok(), Some(100));
        assert_eq!(
            bounded_entity_retention_limit(1_000).ok(),
            Some(MAX_ENTITY_RETENTION_ENQUEUE_LIMIT)
        );
    }

    #[test]
    fn exact_non_null_owner_outcome_is_accepted() {
        let first = "0191fb72-6f06-7ef4-bc18-7e649abe7fd8";
        let second = "0191fb72-92cb-72d9-9879-e1968c79daf8";
        let outcome = parse_entity_retention_enqueue_outcome(
            &json!({
                "evaluatedAt": "2026-08-01T09:49:20.938083Z",
                "enqueuedCount": 2,
                "jobIds": [first, second],
            }),
            100,
        );

        assert_eq!(
            outcome.ok(),
            Some(EntityRetentionEnqueueOutcome {
                evaluated_at: OffsetDateTime::parse("2026-08-01T09:49:20.938083Z", &Rfc3339,)
                    .expect("test timestamp must be RFC 3339"),
                enqueued_count: 2,
            })
        );
    }

    #[test]
    fn malformed_or_inconsistent_owner_outcomes_fail_closed() {
        let job_id = "0191fb72-6f06-7ef4-bc18-7e649abe7fd8";
        let cases = [
            Value::Null,
            json!({
                "evaluatedAt": "2026-08-01T09:49:20Z",
                "enqueuedCount": 0,
                "jobIds": [],
                "unexpected": true,
            }),
            json!({
                "evaluatedAt": "not-a-timestamp",
                "enqueuedCount": 1,
                "jobIds": [job_id],
            }),
            json!({
                "evaluatedAt": "2026-08-01T09:49:20Z",
                "enqueuedCount": 2,
                "jobIds": [job_id],
            }),
            json!({
                "evaluatedAt": "2026-08-01T09:49:20Z",
                "enqueuedCount": 2,
                "jobIds": [job_id, job_id],
            }),
            json!({
                "evaluatedAt": "2026-08-01T09:49:20Z",
                "enqueuedCount": 1,
                "jobIds": [Uuid::nil()],
            }),
        ];

        for value in cases {
            assert!(matches!(
                parse_entity_retention_enqueue_outcome(&value, 100),
                Err(SchedulerError::DatabaseContract(
                    ENTITY_RETENTION_OUTCOME_CONTRACT
                ))
            ));
        }
    }
}
