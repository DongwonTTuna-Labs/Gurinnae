use super::*;

pub(super) async fn arm_assigncorrection(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let correction = uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE editorial.corrections SET assigned_user_id=$2 WHERE id=$1",
        correction,
        assignee,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    upsert_task(
        tx,
        "CORRECTION",
        correction,
        "Correction review",
        "OPEN",
        "HIGH",
        Some(assignee),
        actor,
        None,
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_createcorrection(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let publication =
        uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
    let row = sqlx::query!(
        "SELECT case_id,revision FROM editorial.publication_revisions WHERE id=$1",
        publication,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    sqlx::query!(
        "INSERT INTO editorial.corrections(id,case_id,source_revision,summary,reason, \
         affected_claim_ids,replacement_content,status,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,$7,'DRAFT',$8)",
        id,
        row.case_id,
        row.revision,
        string_value(payload, "summary").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("affectedClaimIds")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("replacementContent")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_resolvecorrectionrequest(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let correction = uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
    let resolution = string_value(payload, "resolution").ok_or(ServiceError::InvalidRequest)?;
    if !matches!(
        resolution,
        "RESOLVED" | "REJECTED" | "DUPLICATE" | "WITHDRAWN"
    ) {
        return Err(ServiceError::InvalidRequest);
    }
    let status = if resolution == "RESOLVED" {
        "PUBLISHED"
    } else {
        "REJECTED"
    };
    let changed = sqlx::query!(
        "UPDATE editorial.corrections SET resolution=$2,resolution_reason=$3, \
         resolved_at=clock_timestamp(),status=$4 WHERE id=$1 AND status='REVIEW'",
        correction,
        resolution,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        status,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    sqlx::query!(
        "UPDATE ops.tasks SET status='DONE',completed_at=clock_timestamp() \
         WHERE object_type='CORRECTION' AND object_id=$1 AND status<>'DONE'",
        correction,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_triagecorrection(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let correction = uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
    let decision = string_value(payload, "decision").ok_or(ServiceError::InvalidRequest)?;
    let status = match decision {
        "ACCEPT" => "REVIEW",
        "NEEDS_INFORMATION" => "DRAFT",
        "REJECT" | "DUPLICATE" => "REJECTED",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let priority = string_value(payload, "priority").ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE editorial.corrections SET triage_decision=$2,priority=$3, \
         triage_reason=$4,status=$5 WHERE id=$1",
        correction,
        decision,
        priority,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        status,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    upsert_task(
        tx,
        "CORRECTION",
        correction,
        "Correction review",
        if status == "REJECTED" { "DONE" } else { "OPEN" },
        priority,
        None,
        actor,
        Some(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_updatecorrectiondraft(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let correction = uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE editorial.corrections SET summary=COALESCE($2,summary),reason=COALESCE($3,reason), \
         affected_claim_ids=COALESCE($4,affected_claim_ids), \
         replacement_content=COALESCE($5,replacement_content) \
         WHERE id=$1 AND status='DRAFT'",
        correction,
        payload.get("summary").and_then(Value::as_str),
        payload.get("reason").and_then(Value::as_str),
        payload.get("affectedClaimIds").cloned(),
        payload.get("replacementContent").cloned(),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}
