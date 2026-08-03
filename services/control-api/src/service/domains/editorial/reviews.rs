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
    sqlx::query(
        "INSERT INTO editorial.review_assignments(id,case_id,review_snapshot_id,reviewer_id, \
         status,assigned_by,assigned_at,due_at) \
         VALUES($1,$2,$3,$4,'ASSIGNED',$5,clock_timestamp(),$6) \
         ON CONFLICT(case_id,review_snapshot_id,reviewer_id) DO UPDATE SET \
         status='ASSIGNED',assigned_by=EXCLUDED.assigned_by,assigned_at=clock_timestamp(), \
         due_at=EXCLUDED.due_at,completed_at=NULL,version=editorial.review_assignments.version+1",
    )
    .bind(assignment_id)
    .bind(case_id)
    .bind(snapshot)
    .bind(reviewer)
    .bind(actor)
    .bind(timestamp_value(payload, "dueAt")?)
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
