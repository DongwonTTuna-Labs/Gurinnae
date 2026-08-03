use super::*;

pub(super) async fn arm_createretractiondraft(
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
    let scope = match string_value(payload, "scope") {
        Some("full") | Some("FULL") => "FULL",
        Some("partial") | Some("PARTIAL") => "PARTIAL",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM editorial.publication_revisions WHERE id=$1)",
    )
    .bind(publication)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !exists {
        return Err(ServiceError::NotFound);
    }
    sqlx::query(
        "INSERT INTO editorial.retraction_drafts(id,publication_revision_id,scope, \
         affected_claim_ids,reason,status,created_by) VALUES($1,$2,$3,$4,$5,'DRAFT',$6)",
    )
    .bind(id)
    .bind(publication)
    .bind(scope)
    .bind(
        payload
            .get("affectedClaimIds")
            .cloned()
            .unwrap_or_else(|| json!([])),
    )
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_createreviewsnapshot(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let claims = uuid_array(payload, "claimIds")?;
    let evidence = uuid_array(payload, "evidenceIds")?;
    let responses = payload
        .get("responseIds")
        .map(|_| uuid_array(payload, "responseIds"))
        .transpose()?
        .unwrap_or_default();
    let case_row = sqlx::query(
        "SELECT title,summary,investigation_state::text investigation_state, \
         publication_state::text publication_state,version FROM editorial.cases WHERE id=$1",
    )
    .bind(case_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let invalid_claims: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM unnest($1::uuid[]) AS selected(id) \
         LEFT JOIN editorial.claims c ON c.id=selected.id AND c.case_id=$2 \
         WHERE c.id IS NULL",
    )
    .bind(&claims)
    .bind(case_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    let invalid_evidence: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM unnest($1::uuid[]) AS selected(id) \
         LEFT JOIN editorial.evidence e ON e.id=selected.id AND e.case_id=$2 \
         WHERE e.id IS NULL",
    )
    .bind(&evidence)
    .bind(case_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if invalid_claims != 0 || invalid_evidence != 0 {
        return Err(ServiceError::InvalidRequest);
    }
    let source_gate: Value = sqlx::query_scalar(
        "WITH grouped AS ( \
           SELECT d.source_id,max(d.retrieved_at) retrieved_at,bool_and(d.status='PARSED') current, \
             COALESCE(jsonb_agg(d.prompt_injection_flags ORDER BY d.retrieved_at) \
               FILTER (WHERE d.prompt_injection_flags<>'[]'::jsonb),'[]'::jsonb) prompt_flags \
           FROM editorial.evidence e JOIN raw.source_documents d ON d.id=e.source_document_id \
           WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) GROUP BY d.source_id \
         ) SELECT jsonb_build_object( \
           'freshness',COALESCE(jsonb_object_agg(source_id,jsonb_build_object( \
             'retrievedAt',retrieved_at,'status',CASE WHEN current THEN 'CURRENT' ELSE 'STALE' END, \
             'promptInjectionFlags',prompt_flags)),'{}'::jsonb), \
           'blockers',COALESCE(jsonb_agg(jsonb_build_object( \
             'code',CASE WHEN NOT current THEN 'SOURCE_FRESHNESS_BLOCKED' \
               ELSE 'PROMPT_INJECTION_FLAGGED' END,'sourceId',source_id)) \
             FILTER (WHERE NOT current OR prompt_flags<>'[]'::jsonb),'[]'::jsonb)) \
         FROM grouped",
    )
    .bind(case_id)
    .bind(&evidence)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    let freshness = source_gate
        .get("freshness")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let blockers = source_gate
        .get("blockers")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let source_freshness_valid = blockers.as_array().is_some_and(Vec::is_empty);
    persist_review_snapshot(
        id,
        actor,
        case_id,
        &claims,
        &evidence,
        &responses,
        invalid_claims,
        invalid_evidence,
        source_freshness_valid,
        freshness,
        blockers,
        &case_row,
        tx,
    )
    .await?;
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "review snapshot persistence binds all signed snapshot provenance"
)]
pub(super) async fn persist_review_snapshot(
    id: Uuid,
    actor: Uuid,
    case_id: Uuid,
    claims: &[Uuid],
    evidence: &[Uuid],
    responses: &[Uuid],
    invalid_claims: i64,
    invalid_evidence: i64,
    source_freshness_valid: bool,
    freshness: Value,
    blockers: Value,
    case_row: &sqlx::postgres::PgRow,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let snapshot = json!({
        "caseId":case_id,
        "caseVersion":case_row.try_get::<i64,_>("version").map_err(db)?,
        "title":case_row.try_get::<String,_>("title").map_err(db)?,
        "summary":case_row.try_get::<Option<String>,_>("summary").map_err(db)?,
        "investigationState":case_row.try_get::<String,_>("investigation_state").map_err(db)?,
        "publicationState":case_row.try_get::<String,_>("publication_state").map_err(db)?,
        "claimIds":claims,
        "evidenceIds":evidence,
        "responseIds":responses,
        "sourceFreshness":freshness,
    });
    let digest = sha256(&serde_json::to_vec(&snapshot).map_err(|_| ServiceError::Persistence)?);
    sqlx::query(
        "INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256, \
         snapshot_payload,automated_gate_results,unresolved_blockers,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
    )
    .bind(id)
    .bind(case_id)
    .bind(
        snapshot
            .get("caseVersion")
            .and_then(Value::as_i64)
            .ok_or(ServiceError::Persistence)?,
    )
    .bind(digest)
    .bind(snapshot)
    .bind(json!({"selectedClaimsValid":invalid_claims==0,
        "selectedEvidenceValid":invalid_evidence==0,
        "sourceFreshnessValid":source_freshness_valid}))
    .bind(blockers)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query("UPDATE editorial.cases SET current_review_snapshot_id=$2 WHERE id=$1")
        .bind(case_id)
        .bind(id)
        .execute(&mut **tx)
        .await
        .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_approveresponseexcerpt(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let response = uuid_value(payload, &["responseId"]).ok_or(ServiceError::InvalidRequest)?;
    let requested = string_value(payload, "excerptHash")
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let excerpt: Option<String> =
        sqlx::query_scalar("SELECT public_excerpt FROM editorial.responses WHERE id=$1")
            .bind(response)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?;
    let excerpt = excerpt.ok_or(ServiceError::InvalidRequest)?;
    if sha256(excerpt.as_bytes()) != requested {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "UPDATE editorial.responses SET public_excerpt_sha256=$2,excerpt_approved_by=$3, \
         excerpt_approved_at=clock_timestamp(),editorial_status= \
         CASE WHEN editorial_status='PENDING' THEN 'ACCEPTED' ELSE editorial_status END \
         WHERE id=$1",
    )
    .bind(response)
    .bind(requested)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_approveschemamapping_rejectschemamapping(
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    decide_schema_mapping(operation, payload, actor, tx).await?;

    Ok(())
}

pub(super) async fn arm_assigncase(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query("UPDATE editorial.cases SET lead_investigator_id=$2 WHERE id=$1")
        .bind(case_id)
        .bind(assignee)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    upsert_task(
        tx,
        "CASE",
        case_id,
        "Case investigation",
        "OPEN",
        "HIGH",
        Some(assignee),
        actor,
        payload.get("reason").and_then(Value::as_str),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_assignsignal(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "UPDATE core.anomaly_signals SET assigned_user_id=$2,status='ASSIGNED' WHERE id=$1",
    )
    .bind(signal)
    .bind(assignee)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    upsert_task(
        tx,
        "SIGNAL",
        signal,
        "Signal triage",
        "OPEN",
        "HIGH",
        Some(assignee),
        actor,
        payload.get("reason").and_then(Value::as_str),
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_acknowledgesourceincident(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.source_incidents SET status='ACKNOWLEDGED',acknowledged_by=$2, \
         acknowledged_at=clock_timestamp() WHERE source_id=$1 AND status='OPEN'",
    )
    .bind(source)
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

pub(super) async fn arm_createaccessrequest(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    sqlx::query(
        "INSERT INTO ops.access_requests(id,requester_user_id,requested_role_codes,reason, \
         requested_until,status) VALUES($1,$2,$3,$4,$5,'PENDING')",
    )
    .bind(id)
    .bind(actor)
    .bind(
        payload
            .get("requestedRoleCodes")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(timestamp_value(payload, "requestedUntil")?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_createsavedview(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if payload.get("isDefault").and_then(Value::as_bool) == Some(true) {
        sqlx::query("UPDATE ops.saved_views SET is_default=false WHERE user_id=$1 AND surface=$2")
            .bind(actor)
            .bind(string_value(payload, "surface").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
    }
    sqlx::query(
        "INSERT INTO ops.saved_views(id,user_id,name,surface,query,is_default) \
         VALUES($1,$2,$3,$4,$5,$6)",
    )
    .bind(id)
    .bind(actor)
    .bind(string_value(payload, "name").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "surface").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("query")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(
        payload
            .get("isDefault")
            .and_then(Value::as_bool)
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_updatesavedview(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let target = uuid_value(payload, &["savedViewId", "id"]).unwrap_or(id);
    if payload.get("isDefault").and_then(Value::as_bool) == Some(true) {
        let surface: String =
            sqlx::query_scalar("SELECT surface FROM ops.saved_views WHERE id=$1 AND user_id=$2")
                .bind(target)
                .bind(actor)
                .fetch_optional(&mut **tx)
                .await
                .map_err(db)?
                .ok_or(ServiceError::NotFound)?;
        sqlx::query("UPDATE ops.saved_views SET is_default=false WHERE user_id=$1 AND surface=$2 AND id<>$3")
            .bind(actor).bind(surface).bind(target).execute(&mut **tx).await.map_err(db)?;
    }
    let changed = sqlx::query(
        "UPDATE ops.saved_views SET name=COALESCE($3,name),query=COALESCE($4,query), \
         is_default=COALESCE($5,is_default) WHERE id=$1 AND user_id=$2",
    )
    .bind(target)
    .bind(actor)
    .bind(payload.get("name").and_then(Value::as_str))
    .bind(payload.get("query").cloned())
    .bind(payload.get("isDefault").and_then(Value::as_bool))
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_deletesavedview(
    _operation: &str,
    _payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query("DELETE FROM ops.saved_views WHERE id=$1 AND user_id=$2")
        .bind(id)
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

pub(super) async fn arm_disableproviderrouting(
    _operation: &str,
    _payload: &Map<String, Value>,
    id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query(
        "UPDATE ops.provider_configs SET enabled=false,last_connection_test_status='DISABLED' \
         WHERE id=$1",
    )
    .bind(id)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}
pub(super) async fn apply_specialized_group_2(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "createRetractionDraft" => {
            arm_createretractiondraft(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "createReviewSnapshot" => {
            arm_createreviewsnapshot(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "approveResponseExcerpt" => {
            arm_approveresponseexcerpt(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "approveSchemaMapping" | "rejectSchemaMapping" => {
            arm_approveschemamapping_rejectschemamapping(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await?
        }
        "assignCase" => {
            arm_assigncase(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "assignSignal" => {
            arm_assignsignal(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "acknowledgeSourceIncident" => {
            arm_acknowledgesourceincident(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "createAccessRequest" => {
            arm_createaccessrequest(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "createSavedView" => {
            arm_createsavedview(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "updateSavedView" => {
            arm_updatesavedview(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "deleteSavedView" => {
            arm_deletesavedview(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "disableProviderRouting" => {
            arm_disableproviderrouting(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    Ok(())
}
