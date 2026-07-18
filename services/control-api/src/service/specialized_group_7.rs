use super::*;

pub(super) async fn arm_revokeownsession(
    _operation: &str,
    _payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query(
        "UPDATE ops.sessions SET revoked_at=clock_timestamp() \
         WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL",
    )
    .bind(session_id)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_revokeusersessions(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(user) = uuid_value(payload, &["userId"]) {
        sqlx::query("UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE user_id=$1 AND revoked_at IS NULL").bind(user).execute(&mut **tx).await.map_err(db)?;
    }

    Ok(())
}

pub(super) async fn arm_canceljob_quarantinejob(
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(job) = uuid_value(payload, &["jobId", "id"]) {
        let status = if operation == "cancelJob" {
            "CANCELLED"
        } else {
            "QUARANTINED"
        };
        sqlx::query("UPDATE ops.jobs SET status=$2::ops.job_status,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,run_after=CASE WHEN $2='QUEUED' THEN clock_timestamp() ELSE run_after END WHERE id=$1").bind(job).bind(status).execute(&mut **tx).await.map_err(db)?;
    }

    Ok(())
}
pub(super) async fn apply_specialized_group_7(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "revokeOwnSession" => {
            arm_revokeownsession(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "revokeUserSessions" => {
            arm_revokeusersessions(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "cancelJob" | "quarantineJob" => {
            arm_canceljob_quarantinejob(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    Ok(())
}
