use super::*;

pub(super) async fn arm_startagentrun(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let evidence = payload
        .get("evidenceScopeIds")
        .cloned()
        .ok_or(ServiceError::InvalidRequest)?;
    let evidence_ids = evidence
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
    if evidence_ids.is_empty() {
        return Err(ServiceError::InvalidRequest);
    }
    let evidence_snapshot: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object( \
           'id',e.id,'contentSha256',btrim(e.content_sha256::text), \
           'locator',e.source_locator,'updatedAt',e.updated_at, \
           'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb) \
         ) ORDER BY e.id),'[]'::jsonb) \
         FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id \
         WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) \
           AND e.verification_status='VERIFIED'",
    )
    .bind(case_id)
    .bind(&evidence_ids)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if evidence_snapshot
        .as_array()
        .is_none_or(|rows| rows.len() != evidence_ids.len())
    {
        return Err(ServiceError::InvalidRequest);
    }
    let snapshot = json!({
        "caseId":case_id,
        "evidence":evidence_snapshot,
        "objective":string_value(payload,"objective").ok_or(ServiceError::InvalidRequest)?,
    });
    sqlx::query(
        "INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids, \
         provider_policy,status,input_snapshot_hash,max_cost,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,'QUEUED',$7,$8,$9)",
    )
    .bind(id)
    .bind(case_id)
    .bind(string_value(payload, "agentType").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "objective").ok_or(ServiceError::InvalidRequest)?)
    .bind(evidence)
    .bind(string_value(payload, "providerPolicy").ok_or(ServiceError::InvalidRequest)?)
    .bind(canonical_json_digest(&snapshot)?)
    .bind(decimal_string(payload, "maxCost")?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "AGENT_RUN",
        "analysis-worker",
        json!({"agentRunId":id}),
        format!("agent-run:{id}"),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_startbackfill(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let from = date_value(payload, "from")?;
    let to = date_value(payload, "to")?;
    if from > to {
        return Err(ServiceError::InvalidRequest);
    }
    let mode = match string_value(payload, "mode") {
        Some("dry_run") => "DRY_RUN",
        Some("execute") => "BACKFILL",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let allowed: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ops.source_registry \
         WHERE source_id=$1 AND enabled AND legal_status='APPROVED')",
    )
    .bind(source)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !allowed {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO ops.source_runs(id,source_id,mode,status,requested_from,requested_to, \
         request_reason,requested_by) VALUES($1,$2,$3,'QUEUED',$4,$5,$6,$7)",
    )
    .bind(id)
    .bind(source)
    .bind(mode)
    .bind(from)
    .bind(to)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "SOURCE_RUN",
        "ingest-worker",
        json!({"sourceRunId":id}),
        format!("source-run:{id}"),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_startruleshadow(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let rule = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let dataset =
        uuid_value(payload, &["datasetSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE core.rule_versions SET status='SHADOW',activation_reason=$2 \
         WHERE id=$1 AND status='DRAFT'",
    )
    .bind(rule)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }
    let evaluation_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id, \
         evaluation_profile,status,requested_by,reason) \
         VALUES($1,$2,$3,'SHADOW','QUEUED',$4,$5)",
    )
    .bind(evaluation_id)
    .bind(rule)
    .bind(dataset)
    .bind(actor)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "RULE_EVALUATION",
        "analysis-worker",
        json!({"evaluationId":evaluation_id}),
        format!("rule-evaluation:{evaluation_id}"),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_startsourcerun(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let mode = match string_value(payload, "mode") {
        Some("incremental") => "INCREMENTAL",
        Some("reconcile") => "RECONCILE",
        Some("full") => "FULL",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let allowed: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ops.source_registry \
         WHERE source_id=$1 AND enabled AND legal_status='APPROVED')",
    )
    .bind(source)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !allowed {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO ops.source_runs(id,source_id,mode,status,request_reason,requested_by) \
         VALUES($1,$2,$3,'QUEUED',$4,$5)",
    )
    .bind(id)
    .bind(source)
    .bind(mode)
    .bind(payload.get("reason").and_then(Value::as_str))
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "SOURCE_RUN",
        "ingest-worker",
        json!({"sourceRunId":id}),
        format!("source-run:{id}"),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_submitreview(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let snapshot =
        uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let decision = match string_value(payload, "decision") {
        Some("approve") | Some("APPROVE") => "APPROVE",
        Some("reject") | Some("REJECT") => "REJECT",
        Some("changes_required") | Some("CHANGES_REQUIRED") => "CHANGES_REQUIRED",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let row = sqlx::query(
        "SELECT a.id,s.created_by snapshot_created_by \
         FROM editorial.review_assignments a \
         JOIN editorial.review_snapshots s ON s.id=$1 AND s.case_id=a.case_id \
         WHERE a.reviewer_id=$2 AND a.status IN ('ASSIGNED','IN_PROGRESS') \
           AND (a.review_snapshot_id IS NULL OR a.review_snapshot_id=$1) \
         ORDER BY a.created_at DESC LIMIT 1 FOR UPDATE OF a",
    )
    .bind(snapshot)
    .bind(actor)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let creator: Uuid = row.try_get("snapshot_created_by").map_err(db)?;
    if creator == actor {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision, \
         reason,criteria,reviewer_independence,reauth_context_hash) \
         VALUES($1,$2,$3::editorial.review_decision,$4,$5,$6,$7)",
    )
    .bind(snapshot)
    .bind(actor)
    .bind(decision)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("criteria")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(json!({"snapshotCreatedBy":creator,"reviewer":actor,"independent":true}))
    .bind(sha256(format!("review:{snapshot}:{actor}").as_bytes()))
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    let assignment: Uuid = row.try_get("id").map_err(db)?;
    sqlx::query(
        "UPDATE editorial.review_assignments SET status='COMPLETED',completed_at=clock_timestamp(), \
         version=version+1 WHERE id=$1",
    )
    .bind(assignment)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query(
        "UPDATE ops.tasks SET status='DONE',completed_at=clock_timestamp() \
         WHERE task_type='REVIEW' AND object_id IN ($1,(SELECT case_id FROM editorial.review_snapshots WHERE id=$1)) \
           AND assignee_user_id=$2 AND status<>'DONE'",
    )
    .bind(snapshot)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_testproviderconnection(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let provider = uuid_value(payload, &["providerId"]).ok_or(ServiceError::InvalidRequest)?;
    let enabled: bool = sqlx::query_scalar("SELECT enabled FROM ops.provider_configs WHERE id=$1")
        .bind(provider)
        .fetch_optional(&mut **tx)
        .await
        .map_err(db)?
        .ok_or(ServiceError::NotFound)?;
    if !enabled {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO ops.provider_connection_tests(id,provider_id,test_model,status, \
         requested_by,reason) VALUES($1,$2,$3,'QUEUED',$4,$5)",
    )
    .bind(id)
    .bind(provider)
    .bind(string_value(payload, "testModel").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .bind(payload.get("reason").and_then(Value::as_str))
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "PROVIDER_CONNECTION_TEST",
        "analysis-worker",
        json!({"providerConnectionTestId":id}),
        format!("provider-connection-test:{id}"),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_transitioncase(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let target = string_value(payload, "targetState").ok_or(ServiceError::InvalidRequest)?;
    let current: String =
        sqlx::query_scalar("SELECT investigation_state::text FROM editorial.cases WHERE id=$1")
            .bind(case_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
    if !valid_case_transition(&current, target) {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "UPDATE editorial.cases SET investigation_state=$2::editorial.investigation_state \
         WHERE id=$1",
    )
    .bind(case_id)
    .bind(target)
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
    let changed = sqlx::query(
        "UPDATE editorial.corrections SET triage_decision=$2,priority=$3, \
         triage_reason=$4,status=$5 WHERE id=$1",
    )
    .bind(correction)
    .bind(decision)
    .bind(priority)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(status)
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

pub(super) async fn apply_specialized_group_5(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "startAgentRun" => {
            arm_startagentrun(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "startBackfill" => {
            arm_startbackfill(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "startRuleShadow" => {
            arm_startruleshadow(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "startSourceRun" => {
            arm_startsourcerun(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "submitReview" => {
            arm_submitreview(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "testProviderConnection" => {
            arm_testproviderconnection(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "transitionCase" => {
            arm_transitioncase(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "triageCorrection" => {
            arm_triagecorrection(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "triageSignal" => {
            arm_triagesignal(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    Ok(())
}
