use super::*;

pub(super) async fn arm_reassigntask(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.tasks SET assignee_user_id=$2,assigned_by=$3, \
         assignment_reason='reassigned by control command' WHERE id=$1",
    )
    .bind(id)
    .bind(assignee)
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

pub(super) async fn arm_proposeroledefinitionchange(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO ops.role_change_proposals(id,role_id,add_capabilities, \
         remove_capabilities,reason,status,proposed_by) \
         VALUES($1,$2,$3,$4,$5,'REVIEW',$6)",
    )
    .bind(id)
    .bind(role)
    .bind(
        payload
            .get("addCapabilities")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(
        payload
            .get("removeCapabilities")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_revokerole(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let user = uuid_value(payload, &["userId"]).ok_or(ServiceError::InvalidRequest)?;
    let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.user_roles SET revoked_at=clock_timestamp(),revoked_by=$3,version=version+1 \
         WHERE user_id=$1 AND role_id=$2 AND revoked_at IS NULL",
    )
    .bind(user)
    .bind(role)
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

pub(super) async fn arm_retryjob(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let job = uuid_value(payload, &["jobId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.jobs SET status='QUEUED',run_after=clock_timestamp(),lease_owner=NULL, \
         lease_token=NULL,lease_expires_at=NULL,last_error_code=NULL,last_error_detail=$2, \
         completed_at=NULL WHERE id=$1 AND status IN ('FAILED','DEAD_LETTER')",
    )
    .bind(job)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

pub(super) async fn arm_retryjobs(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let max_count = payload
        .get("maxCount")
        .and_then(Value::as_i64)
        .filter(|value| (1..=1000).contains(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let selected = if payload.contains_key("jobIds") {
        uuid_array(payload, "jobIds")?
    } else if let Some(snapshot) = uuid_value(payload, &["querySnapshotId"]) {
        sqlx::query_scalar::<_, Vec<Uuid>>(
            "SELECT selected_job_ids FROM ops.job_query_snapshots \
             WHERE id=$1 AND actor_user_id=$2 AND expires_at>clock_timestamp()",
        )
        .bind(snapshot)
        .bind(actor)
        .fetch_optional(&mut **tx)
        .await
        .map_err(db)?
        .ok_or(ServiceError::NotFound)?
    } else {
        return Err(ServiceError::InvalidRequest);
    };
    if selected.is_empty() || selected.len() as i64 > max_count {
        return Err(ServiceError::InvalidRequest);
    }
    let rows = sqlx::query(
        "UPDATE ops.jobs SET status='QUEUED',run_after=clock_timestamp(),lease_owner=NULL, \
         lease_token=NULL,lease_expires_at=NULL,last_error_code=NULL,last_error_detail=$2, \
         completed_at=NULL,version=version+1 \
         WHERE id=ANY($1::uuid[]) AND status IN ('FAILED','DEAD_LETTER')",
    )
    .bind(&selected)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if rows != selected.len() as u64 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

pub(super) async fn arm_retrysourcerun(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source_run = uuid_value(payload, &["sourceRunId"]).ok_or(ServiceError::InvalidRequest)?;
    let row = sqlx::query(
        "SELECT source_id,mode,checkpoint_before FROM ops.source_runs \
         WHERE id=$1 AND status IN ('FAILED','CANCELLED')",
    )
    .bind(source_run)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::VersionConflict)?;
    sqlx::query(
        "INSERT INTO ops.source_runs(id,source_id,mode,checkpoint_before,status, \
         retry_of_source_run_id,request_reason,requested_by) \
         VALUES($1,$2,$3,$4,'QUEUED',$5,$6,$7)",
    )
    .bind(Uuid::new_v4())
    .bind(row.try_get::<String, _>("source_id").map_err(db)?)
    .bind(row.try_get::<String, _>("mode").map_err(db)?)
    .bind(
        row.try_get::<Option<Value>, _>("checkpoint_before")
            .map_err(db)?,
    )
    .bind(source_run)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_rollbackruleversion(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let current = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let target = uuid_value(payload, &["targetVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let same_rule: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM core.rule_versions target \
         JOIN core.rule_versions current ON current.id=$1 \
         WHERE target.id=$2 AND target.rule_id=current.rule_id \
           AND target.status IN ('RETIRED','ROLLED_BACK','ACTIVE'))",
    )
    .bind(current)
    .bind(target)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !same_rule {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "UPDATE core.rule_versions SET status='ROLLED_BACK',retired_at=clock_timestamp(), \
         activation_reason=$2 WHERE id=$1",
    )
    .bind(current)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query(
        "UPDATE core.rule_versions SET status='ACTIVE',effective_at=clock_timestamp(), \
         retired_at=NULL WHERE id=$1",
    )
    .bind(target)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_runruleevaluation(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let rule = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let dataset =
        uuid_value(payload, &["datasetSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id, \
         evaluation_profile,status,requested_by,reason) \
         VALUES($1,$2,$3,$4,'QUEUED',$5,$6)",
    )
    .bind(id)
    .bind(rule)
    .bind(dataset)
    .bind(string_value(payload, "evaluationProfile").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "RULE_EVALUATION",
        "analysis-worker",
        json!({"evaluationId":id}),
        format!("rule-evaluation:{id}"),
    )
    .await?;

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
    let changed = sqlx::query(
        "UPDATE editorial.corrections SET resolution=$2,resolution_reason=$3, \
         resolved_at=clock_timestamp(),status=$4 WHERE id=$1 AND status='REVIEW'",
    )
    .bind(correction)
    .bind(resolution)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(status)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    sqlx::query(
        "UPDATE ops.tasks SET status='DONE',completed_at=clock_timestamp() \
         WHERE object_type='CORRECTION' AND object_id=$1 AND status<>'DONE'",
    )
    .bind(correction)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_saveresponserequestdraft(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let request =
        uuid_value(payload, &["responseRequestId"]).ok_or(ServiceError::InvalidRequest)?;
    let (email_hash, encrypted) =
        if let Some(raw) = payload.get("recipientEmail").and_then(Value::as_str) {
            let email = normalized_email(raw)?;
            (
                Some(sha256(email.as_bytes())),
                Some(encrypt_control_field(
                    field_keys,
                    "editorial.response_requests",
                    "recipient_email_encrypted",
                    request,
                    "email-address",
                    email.as_bytes(),
                )?),
            )
        } else {
            (None, None)
        };
    let changed = sqlx::query(
        "UPDATE editorial.response_requests SET recipient_email_hash=COALESCE($2,recipient_email_hash), \
         recipient_email_encrypted=COALESCE($3,recipient_email_encrypted), \
         questions=COALESCE($4,questions),due_at=COALESCE($5,due_at), \
         requested_publication_scope=COALESCE($6,requested_publication_scope) \
         WHERE id=$1 AND status='DRAFT'",
    )
    .bind(request)
    .bind(email_hash)
    .bind(encrypted)
    .bind(payload.get("questions").cloned())
    .bind(timestamp_value(payload, "dueAt")?)
    .bind(payload.get("requestedPublicationScope").cloned())
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

pub(super) async fn arm_startaccessreview(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let reviewers = uuid_array(payload, "reviewerUserIds")?;
    if reviewers.is_empty() {
        return Err(ServiceError::InvalidRequest);
    }
    let scope = string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?;
    let scope_id = uuid_value(payload, &["scopeId"]);
    sqlx::query(
        "INSERT INTO ops.access_reviews(id,scope,scope_id,reviewer_user_ids,due_at,reason, \
         status,created_by) VALUES($1,$2,$3,$4,$5,$6,'OPEN',$7)",
    )
    .bind(id)
    .bind(scope)
    .bind(scope_id)
    .bind(
        payload
            .get("reviewerUserIds")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(timestamp_value(payload, "dueAt")?.ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    for reviewer in reviewers {
        sqlx::query(
            "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority, \
             assignee_user_id,due_at,assigned_by,assignment_reason) \
             VALUES('ACCESS_REVIEW','ACCESS_REVIEW',$1,'Access review','OPEN','HIGH',$2,$3,$4,$5)",
        )
        .bind(id)
        .bind(reviewer)
        .bind(timestamp_value(payload, "dueAt")?)
        .bind(actor)
        .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }

    Ok(())
}
pub(super) async fn apply_specialized_group_4(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "reassignTask" => {
            arm_reassigntask(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "proposeRoleDefinitionChange" => {
            arm_proposeroledefinitionchange(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await?
        }
        "revokeRole" => {
            arm_revokerole(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "retryJob" => {
            arm_retryjob(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "retryJobs" => {
            arm_retryjobs(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "retrySourceRun" => {
            arm_retrysourcerun(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "rollbackRuleVersion" => {
            arm_rollbackruleversion(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "runRuleEvaluation" => {
            arm_runruleevaluation(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "resolveCorrectionRequest" => {
            arm_resolvecorrectionrequest(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "saveResponseRequestDraft" => {
            arm_saveresponserequestdraft(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "startAccessReview" => {
            arm_startaccessreview(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    Ok(())
}
