use super::*;

pub(super) async fn decide_schema_mapping(
    operation: &str,
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let decision = parse_schema_mapping_decision(operation, payload)?;
    let current_status = lock_schema_mapping(&decision, tx).await?;
    let drift_status = match operation {
        "approveSchemaMapping" => {
            approve_schema_mapping(&decision, current_status.as_deref(), actor, tx).await?;
            "RESOLVED"
        }
        "rejectSchemaMapping" => {
            reject_schema_mapping(&decision, current_status.as_deref(), actor, tx).await?;
            "REJECTED"
        }
        _ => return Err(ServiceError::InvalidRequest),
    };
    finish_schema_drift_decision(decision.drift, drift_status, tx).await
}

pub(super) fn parse_schema_mapping_decision(
    operation: &str,
    payload: &Map<String, Value>,
) -> Result<SchemaMappingDecision, ServiceError> {
    let drift = uuid_value(payload, &["schemaDriftId"]).ok_or(ServiceError::InvalidRequest)?;
    let mapping_version = payload
        .get("mappingVersion")
        .and_then(Value::as_i64)
        .and_then(|value| i32::try_from(value).ok())
        .filter(|value| *value > 0)
        .ok_or(ServiceError::InvalidRequest)?;
    let digest = string_value(payload, "mappingDigest")
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)?
        .to_owned();
    let reason = string_value(payload, "reason")
        .ok_or(ServiceError::InvalidRequest)?
        .to_owned();
    let field_mappings = if operation == "approveSchemaMapping" {
        let value = payload
            .get("fieldMappings")
            .filter(|value| value.is_array())
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?;
        if !mapping_digest_matches(&value, &digest)? {
            return Err(ServiceError::InvalidRequest);
        }
        Some(value)
    } else if operation == "rejectSchemaMapping" {
        None
    } else {
        return Err(ServiceError::InvalidRequest);
    };
    Ok(SchemaMappingDecision {
        drift,
        mapping_version,
        digest,
        reason,
        field_mappings,
    })
}

pub(super) async fn lock_schema_mapping(
    decision: &SchemaMappingDecision,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Option<String>, ServiceError> {
    let candidates = sqlx::query(
        "SELECT mapping_version,mapping_digest,status FROM ops.schema_mappings \
         WHERE schema_drift_id=$1 AND (mapping_version=$2 OR mapping_digest=$3) FOR UPDATE",
    )
    .bind(decision.drift)
    .bind(decision.mapping_version)
    .bind(&decision.digest)
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if candidates.len() > 1 {
        return Err(ServiceError::VersionConflict);
    }
    let Some(row) = candidates.first() else {
        return Ok(None);
    };
    let version = row.try_get::<i32, _>("mapping_version").map_err(db)?;
    let digest = row
        .try_get::<String, _>("mapping_digest")
        .map_err(db)?
        .trim()
        .to_owned();
    if version != decision.mapping_version || digest != decision.digest {
        return Err(ServiceError::VersionConflict);
    }
    row.try_get::<String, _>("status").map(Some).map_err(db)
}

pub(super) async fn approve_schema_mapping(
    decision: &SchemaMappingDecision,
    current_status: Option<&str>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match current_status {
        None => insert_approved_schema_mapping(decision, actor, tx).await,
        Some("DRAFT") => update_approved_schema_mapping(decision, actor, tx).await,
        Some(_) => Err(ServiceError::VersionConflict),
    }
}

pub(super) async fn insert_approved_schema_mapping(
    decision: &SchemaMappingDecision,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let field_mappings = decision
        .field_mappings
        .as_ref()
        .ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO ops.schema_mappings(schema_drift_id,mapping_version,mapping_digest, \
         field_mappings,status,proposed_by,decided_by,decision_reason,decided_at) \
         VALUES($1,$2,$3,$4,'APPROVED',$5,$5,$6,clock_timestamp())",
    )
    .bind(decision.drift)
    .bind(decision.mapping_version)
    .bind(&decision.digest)
    .bind(field_mappings)
    .bind(actor)
    .bind(&decision.reason)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    Ok(())
}

pub(super) async fn update_approved_schema_mapping(
    decision: &SchemaMappingDecision,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let field_mappings = decision
        .field_mappings
        .as_ref()
        .ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.schema_mappings SET field_mappings=$4,status='APPROVED',decided_by=$5, \
         decision_reason=$6,decided_at=clock_timestamp() WHERE schema_drift_id=$1 \
         AND mapping_version=$2 AND mapping_digest=$3 AND status='DRAFT'",
    )
    .bind(decision.drift)
    .bind(decision.mapping_version)
    .bind(&decision.digest)
    .bind(field_mappings)
    .bind(actor)
    .bind(&decision.reason)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(ServiceError::VersionConflict)
    }
}

pub(super) async fn reject_schema_mapping(
    decision: &SchemaMappingDecision,
    current_status: Option<&str>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match current_status {
        None => return Err(ServiceError::NotFound),
        Some("DRAFT") => {}
        Some(_) => return Err(ServiceError::VersionConflict),
    }
    let changed = sqlx::query(
        "UPDATE ops.schema_mappings SET status='REJECTED',decided_by=$4, \
         decision_reason=$5,decided_at=clock_timestamp() WHERE schema_drift_id=$1 \
         AND mapping_version=$2 AND mapping_digest=$3 AND status='DRAFT'",
    )
    .bind(decision.drift)
    .bind(decision.mapping_version)
    .bind(&decision.digest)
    .bind(actor)
    .bind(&decision.reason)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(ServiceError::VersionConflict)
    }
}

pub(super) async fn finish_schema_drift_decision(
    drift: Uuid,
    status: &str,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed =
        sqlx::query("UPDATE ops.schema_drifts SET status=$2 WHERE id=$1 AND status='OPEN'")
            .bind(drift)
            .bind(status)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(ServiceError::VersionConflict)
    }
}

pub(super) async fn replace_claim_relations(
    claim: Uuid,
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(values) = payload.get("evidenceIds") {
        sqlx::query("DELETE FROM editorial.claim_evidence WHERE claim_id=$1")
            .bind(claim)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        let ids = values
            .as_array()
            .ok_or(ServiceError::InvalidRequest)?
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .ok_or(ServiceError::InvalidRequest)
            })
            .collect::<Result<Vec<_>, _>>()?;
        for (index, evidence) in ids.into_iter().enumerate() {
            sqlx::query(
                "INSERT INTO editorial.claim_evidence(claim_id,evidence_id,citation_label, \
                 citation_order,supports) VALUES($1,$2,$3,$4,'FACT')",
            )
            .bind(claim)
            .bind(evidence)
            .bind(format!("E{}", index + 1))
            .bind(i32::try_from(index + 1).map_err(|_| ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
    }
    if let Some(values) = payload.get("responseIds") {
        sqlx::query("DELETE FROM editorial.claim_responses WHERE claim_id=$1")
            .bind(claim)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        let ids = values.as_array().ok_or(ServiceError::InvalidRequest)?;
        for response in ids {
            let response = response
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.claim_responses(claim_id,response_id,relation) \
                 VALUES($1,$2,'RESPONDS')",
            )
            .bind(claim)
            .bind(response)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
    }
    Ok(())
}

pub(super) async fn enqueue_runtime_job(
    tx: &mut Transaction<'_, Postgres>,
    job_type: &str,
    queue: &str,
    payload: Value,
    dedupe_key: String,
) -> Result<(), ServiceError> {
    sqlx::query(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
         VALUES($1,$2,$3,$4,8)",
    )
    .bind(job_type)
    .bind(queue)
    .bind(payload)
    .bind(dedupe_key)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "task upsert binds aggregate, assignment, and audit fields"
)]
pub(super) async fn upsert_task(
    tx: &mut Transaction<'_, Postgres>,
    task_type: &str,
    object_id: Uuid,
    title: &str,
    status: &str,
    priority: &str,
    assignee: Option<Uuid>,
    actor: Uuid,
    reason: Option<&str>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query(
        "UPDATE ops.tasks SET title=$3,status=$4,priority=$5, \
         assignee_user_id=COALESCE($6,assignee_user_id),assigned_by=$7, \
         assignment_reason=COALESCE($8,assignment_reason), \
         completed_at=CASE WHEN $4='DONE' THEN clock_timestamp() ELSE NULL END \
         WHERE task_type=$1 AND object_type=$1 AND object_id=$2 AND status<>'CANCELLED'",
    )
    .bind(task_type)
    .bind(object_id)
    .bind(title)
    .bind(status)
    .bind(priority)
    .bind(assignee)
    .bind(actor)
    .bind(reason)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed == 0 {
        sqlx::query(
            "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority, \
             assignee_user_id,assigned_by,assignment_reason,completed_at) \
             VALUES($1,$1,$2,$3,$4,$5,$6,$7,$8, \
             CASE WHEN $4='DONE' THEN clock_timestamp() ELSE NULL END)",
        )
        .bind(task_type)
        .bind(object_id)
        .bind(title)
        .bind(status)
        .bind(priority)
        .bind(assignee)
        .bind(actor)
        .bind(reason)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }
    Ok(())
}

pub(super) async fn replace_hypothesis_relations(
    hypothesis: Uuid,
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if !payload.contains_key("supportingEvidenceIds")
        && !payload.contains_key("contradictingEvidenceIds")
    {
        return Ok(());
    }
    sqlx::query("DELETE FROM editorial.hypothesis_evidence WHERE hypothesis_id=$1")
        .bind(hypothesis)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    for (key, relation) in [
        ("supportingEvidenceIds", "SUPPORTS"),
        ("contradictingEvidenceIds", "CONTRADICTS"),
    ] {
        if let Some(values) = payload.get(key) {
            for evidence in values.as_array().ok_or(ServiceError::InvalidRequest)? {
                let evidence = evidence
                    .as_str()
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .ok_or(ServiceError::InvalidRequest)?;
                sqlx::query(
                    "INSERT INTO editorial.hypothesis_evidence(hypothesis_id,evidence_id,relation,added_by) \
                     VALUES($1,$2,$3,$4)",
                )
                .bind(hypothesis)
                .bind(evidence)
                .bind(relation)
                .bind(actor)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
            }
        }
    }
    Ok(())
}

pub(super) struct SchemaMappingDecision {
    drift: Uuid,
    mapping_version: i32,
    digest: String,
    reason: String,
    field_mappings: Option<Value>,
}
