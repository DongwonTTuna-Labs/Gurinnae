use super::*;

pub(super) async fn arm_assignreview(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let snapshot = uuid_value(payload, &["reviewSnapshotId"]);
    let reviewer = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignment_id = Uuid::new_v4();
    sqlx::query!(
        "INSERT INTO editorial.review_assignments(id,case_id,review_snapshot_id,reviewer_id, \
         status,assigned_by,assigned_at,due_at) \
         VALUES($1,$2,$3,$4,'ASSIGNED',$5,clock_timestamp(),$6) \
         ON CONFLICT(case_id,review_snapshot_id,reviewer_id) DO UPDATE SET \
         status='ASSIGNED',assigned_by=EXCLUDED.assigned_by,assigned_at=clock_timestamp(), \
         due_at=EXCLUDED.due_at,completed_at=NULL,version=editorial.review_assignments.version+1",
        assignment_id,
        case_id,
        snapshot,
        reviewer,
        actor,
        timestamp_value(payload, "dueAt")?,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    upsert_task(
        tx,
        "REVIEW",
        snapshot.unwrap_or(case_id),
        "Editorial review",
        "OPEN",
        "HIGH",
        Some(reviewer),
        actor,
        None,
    )
    .await?;

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
    let responses = review_response_ids(payload)?;
    let case_row = sqlx::query!(
        "SELECT title,summary,investigation_state::text investigation_state, \
         publication_state::text publication_state,version FROM editorial.cases WHERE id=$1",
        case_id,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let invalid_claims: i64 = sqlx::query_scalar!(
        "SELECT count(*) FROM unnest($1::uuid[]) AS selected(id) \
         LEFT JOIN editorial.claims c ON c.id=selected.id AND c.case_id=$2 \
         WHERE c.id IS NULL",
        &claims,
        case_id,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let invalid_evidence: i64 = sqlx::query_scalar!(
        "SELECT count(*) FROM unnest($1::uuid[]) AS selected(id) \
         LEFT JOIN editorial.evidence e ON e.id=selected.id AND e.case_id=$2 \
         WHERE e.id IS NULL",
        &evidence,
        case_id,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    if invalid_claims != 0 || invalid_evidence != 0 {
        return Err(ServiceError::InvalidRequest);
    }
    let source_gate: Value = sqlx::query_scalar!(
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
        case_id,
        &evidence,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let (freshness, blockers, source_freshness_valid) = source_gate_parts(&source_gate)?;
    let snapshot_payload = json!({
        "caseId":case_id,
        "caseVersion":case_row.version,
        "title":case_row.title,
        "summary":case_row.summary,
        "investigationState":case_row.investigation_state.ok_or_else(unexpected_null)?,
        "publicationState":case_row.publication_state.ok_or_else(unexpected_null)?,
        "claimIds":claims,
        "evidenceIds":evidence,
        "responseIds":responses,
        "sourceFreshness":freshness,
    });
    persist_review_snapshot(
        id,
        actor,
        case_id,
        invalid_claims,
        invalid_evidence,
        source_freshness_valid,
        snapshot_payload,
        blockers,
        tx,
    )
    .await?;
    Ok(())
}

fn review_response_ids(payload: &Map<String, Value>) -> Result<Vec<Uuid>, ServiceError> {
    Ok(payload
        .get("responseIds")
        .map(|_| uuid_array(payload, "responseIds"))
        .transpose()?
        .unwrap_or_default())
}

fn source_gate_parts(source_gate: &Value) -> Result<(Value, Value, bool), ServiceError> {
    let freshness = source_gate
        .get("freshness")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let blockers = source_gate
        .get("blockers")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let source_freshness_valid = blockers.as_array().is_some_and(Vec::is_empty);
    Ok((freshness, blockers, source_freshness_valid))
}

#[expect(
    clippy::too_many_arguments,
    reason = "review snapshot persistence binds all signed snapshot provenance"
)]
pub(super) async fn persist_review_snapshot(
    id: Uuid,
    actor: Uuid,
    case_id: Uuid,
    invalid_claims: i64,
    invalid_evidence: i64,
    source_freshness_valid: bool,
    snapshot: Value,
    blockers: Value,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let digest = sha256(&serde_json::to_vec(&snapshot).map_err(|_| ServiceError::Persistence)?);
    sqlx::query!(
        "INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256, \
         snapshot_payload,automated_gate_results,unresolved_blockers,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
        id,
        case_id,
        snapshot
            .get("caseVersion")
            .and_then(Value::as_i64)
            .ok_or(ServiceError::Persistence)?,
        digest,
        snapshot,
        json!({"selectedClaimsValid":invalid_claims==0,
            "selectedEvidenceValid":invalid_evidence==0,
            "sourceFreshnessValid":source_freshness_valid}),
        blockers,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query!(
        "UPDATE editorial.cases SET current_review_snapshot_id=$2 WHERE id=$1",
        case_id,
        id,
    )
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
    let excerpt: Option<String> = sqlx::query_scalar!(
        "SELECT public_excerpt FROM editorial.responses WHERE id=$1",
        response
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let excerpt = excerpt.ok_or(ServiceError::InvalidRequest)?;
    if sha256(excerpt.as_bytes()) != requested {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query!(
        "UPDATE editorial.responses SET public_excerpt_sha256=$2,excerpt_approved_by=$3, \
         excerpt_approved_at=clock_timestamp(),editorial_status= \
         CASE WHEN editorial_status='PENDING' THEN 'ACCEPTED' ELSE editorial_status END \
         WHERE id=$1",
        response,
        requested,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

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
    let row = sqlx::query!(
        "SELECT a.id,s.created_by snapshot_created_by \
         FROM editorial.review_assignments a \
         JOIN editorial.review_snapshots s ON s.id=$1 AND s.case_id=a.case_id \
         WHERE a.reviewer_id=$2 AND a.status IN ('ASSIGNED','IN_PROGRESS') \
           AND (a.review_snapshot_id IS NULL OR a.review_snapshot_id=$1) \
         ORDER BY a.created_at DESC LIMIT 1 FOR UPDATE OF a",
        snapshot,
        actor,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let creator = row.snapshot_created_by;
    if creator == actor {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query!(
        "INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision, \
         reason,criteria,reviewer_independence,reauth_context_hash) \
         VALUES($1,$2,$3::editorial.review_decision,$4,$5,$6,$7)",
        snapshot,
        actor,
        decision as _,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("criteria")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        json!({"snapshotCreatedBy":creator,"reviewer":actor,"independent":true}),
        sha256(format!("review:{snapshot}:{actor}").as_bytes()),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    let assignment = row.id;
    sqlx::query!(
        "UPDATE editorial.review_assignments SET status='COMPLETED',completed_at=clock_timestamp(), \
         version=version+1 WHERE id=$1",
        assignment,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query!(
        "UPDATE ops.tasks SET status='DONE',completed_at=clock_timestamp() \
         WHERE task_type='REVIEW' AND object_id IN ($1,(SELECT case_id FROM editorial.review_snapshots WHERE id=$1)) \
           AND assignee_user_id=$2 AND status<>'DONE'",
        snapshot,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}
