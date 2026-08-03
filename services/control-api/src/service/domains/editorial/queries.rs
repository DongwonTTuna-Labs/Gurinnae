use super::*;

pub(super) async fn query_correction_workspace(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "correctionId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'caseId',case_id,'sourceRevision',source_revision, \
         'targetRevision',target_revision,'summary',summary,'reason',reason,'affectedClaimIds', \
         affected_claim_ids,'replacementContent',replacement_content,'status',status, \
         'assignedUserId',assigned_user_id,'resolution',resolution,'version',version) \
         FROM editorial.corrections WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

pub(super) async fn query_response_request_composer(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    case_query("getResponseRequestComposer", parameters, pool).await
}

pub(super) async fn query_review_readiness(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    case_query("getReviewReadiness", parameters, pool).await
}

pub(super) async fn get_publication_preview(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let snapshot = query_uuid(parameters, "reviewSnapshotId")?;
    let row = sqlx::query(
        "SELECT preview_sha256,preview_payload,expires_at FROM editorial.publication_previews \
         WHERE case_id=$1 AND review_snapshot_id=$2 AND expires_at>clock_timestamp() \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(case_id)
    .bind(snapshot)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"previewHash":row.try_get::<String,_>("preview_sha256").map_err(db)?.trim(),
        "caseId":case_id,"snapshotId":snapshot,
        "publicPayload":row.try_get::<Value,_>("preview_payload").map_err(db)?,
        "validation":[],"renderedRoutes":[],
        "expiresAt":format_time(row.try_get("expires_at").map_err(db)?)?}),
    )
}

pub(super) async fn get_publication_receipt(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "publicationId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',r.id,'caseId',r.case_id,'revision',r.revision, \
         'state',r.state::text,'reviewSnapshotId',r.review_snapshot_id, \
         'publicPayloadSha256',r.public_payload_sha256,'previewSha256',r.preview_sha256, \
         'publishedBy',r.published_by,'publishedAt',r.published_at, \
         'supersedesRevision',r.supersedes_revision,'reason',r.reason) \
         FROM editorial.publication_revisions r WHERE r.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

pub(super) async fn get_publish_confirmation(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let snapshot = query_uuid(parameters, "reviewSnapshotId")?;
    let row = sqlx::query(
        "SELECT c.version,c.current_review_snapshot_id,s.snapshot_sha256,s.unresolved_blockers, \
         EXISTS(SELECT 1 FROM editorial.review_decisions d WHERE d.review_snapshot_id=s.id \
           AND d.decision='APPROVE' AND d.reviewer_id<>s.created_by) approved, \
         EXISTS(SELECT 1 FROM ops.kill_switches WHERE state='ACTIVE' \
           AND (expires_at IS NULL OR expires_at>clock_timestamp())) kill_switch \
         FROM editorial.cases c JOIN editorial.review_snapshots s ON s.id=$2 AND s.case_id=c.id \
         WHERE c.id=$1",
    )
    .bind(case_id)
    .bind(snapshot)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let current: Option<Uuid> = row.try_get("current_review_snapshot_id").map_err(db)?;
    let approved: bool = row.try_get("approved").map_err(db)?;
    let kill_switch: bool = row.try_get("kill_switch").map_err(db)?;
    let unresolved: Value = row.try_get("unresolved_blockers").map_err(db)?;
    let ready = current == Some(snapshot)
        && approved
        && !kill_switch
        && unresolved.as_array().is_some_and(Vec::is_empty);
    Ok(envelope(
        case_id,
        if ready { "READY" } else { "BLOCKED" },
        json!({"caseId":case_id,"reviewSnapshotId":snapshot,
            "caseVersion":row.try_get::<i64,_>("version").map_err(db)?,
            "snapshotHash":row.try_get::<String,_>("snapshot_sha256").map_err(db)?.trim(),
            "humanApproval":approved,"killSwitchActive":kill_switch,
            "unresolvedBlockers":unresolved}),
    ))
}

pub(super) async fn get_review_snapshot(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "reviewSnapshotId")?;
    let row = sqlx::query(
        "SELECT case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results, \
         unresolved_blockers,created_by,created_at FROM editorial.review_snapshots WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let payload: Value = row.try_get("snapshot_payload").map_err(db)?;
    Ok(
        json!({"snapshotId":id,"caseId":row.try_get::<Uuid,_>("case_id").map_err(db)?,
        "caseVersion":row.try_get::<i64,_>("case_version").map_err(db)?,
        "snapshotHash":row.try_get::<String,_>("snapshot_sha256").map_err(db)?.trim(),
        "createdAt":format_time(row.try_get("created_at").map_err(db)?)?,
        "createdBy":row.try_get::<Uuid,_>("created_by").map_err(db)?,
        "claims":payload.get("claimIds").cloned().unwrap_or(json!([])),
        "evidence":payload.get("evidenceIds").cloned().unwrap_or(json!([])),
        "responses":payload.get("responseIds").cloned().unwrap_or(json!([])),
        "automatedGates":row.try_get::<Value,_>("automated_gate_results").map_err(db)?,
        "independence":{},"unresolvedBlockers":row.try_get::<Value,_>("unresolved_blockers").map_err(db)?,
        "diffFromCurrent":[]}),
    )
}

pub(super) async fn list_case_corrections(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'sourceRevision',source_revision,'targetRevision',target_revision,'summary',summary,'reason',reason,'status',status,'resolution',resolution,'version',version) ORDER BY created_at DESC),'[]'::jsonb) FROM editorial.corrections WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

pub(super) async fn list_case_responses(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'responseRequestId',response_request_id,'partyName',party_name,'submittedAt',submitted_at,'verifiedAt',verified_at,'publicExcerpt',public_excerpt,'publicationConsent',publication_consent,'editorialStatus',editorial_status,'version',version) ORDER BY submitted_at DESC),'[]'::jsonb) FROM editorial.responses WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

pub(super) async fn list_correction_queue(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',x.id,'caseId',x.case_id,'caseTitle',c.title,'status',x.status,'summary',x.summary,'priority',x.priority,'assignedUserId',x.assigned_user_id,'version',x.version) ORDER BY x.updated_at DESC),'[]'::jsonb) FROM editorial.corrections x JOIN editorial.cases c ON c.id=x.case_id WHERE x.status IN ('DRAFT','REVIEW')").fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

pub(super) async fn list_review_queue(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',a.id,'caseId',a.case_id,'reviewSnapshotId',a.review_snapshot_id,'reviewerId',a.reviewer_id,'status',a.status::text,'dueAt',a.due_at,'version',a.version,'caseTitle',c.title) ORDER BY a.due_at NULLS LAST,a.created_at),'[]'::jsonb) FROM editorial.review_assignments a JOIN editorial.cases c ON c.id=a.case_id WHERE a.status IN ('ASSIGNED','IN_PROGRESS')").fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

fn list_response(
    items: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}

pub(super) async fn get_communication_delivery_receipt(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "deliveryId")?;
    let value: Option<Value> =
        sqlx::query_scalar("SELECT ops.read_communication_delivery_receipt_v1($1)")
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(db)?;
    value.ok_or(ServiceError::NotFound)
}

pub(super) async fn get_response_appeal_workspace(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "appealId")?;
    let value: Option<Value> = sqlx::query_scalar("SELECT ops.read_appeal_workspace_v1($1)")
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(db)?;
    value.ok_or(ServiceError::NotFound)
}

pub(super) async fn list_response_appeals(pool: &PgPool) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar("SELECT ops.read_appeal_queue_v1()")
        .fetch_one(pool)
        .await
        .map_err(db)?;
    let items = normalize_appeal_queue_items(items);
    let as_of = format_time(OffsetDateTime::now_utc())?;
    Ok(
        json!({"items":items,"appliedFilters":{"state":[],"caseId":null,"dueBefore":null,"sort":"DUE_ASC"},"asOf":as_of,"nextCursor":null,"totalApproximate":null,"operationId":"listResponseAppeals","links":[]}),
    )
}

fn normalize_appeal_queue_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else {
        return json!([]);
    };
    Value::Array(rows.iter().filter_map(|row| {
        let appeal_id = row.get("id")?.clone();
        Some(json!({
            "appealId": appeal_id,
            "responseRequestId": row.get("response_request_id").cloned().unwrap_or(Value::Null),
            "caseId": row.get("case_id").cloned().unwrap_or(Value::Null),
            "decisionSequence": row.get("decision_sequence").cloned().unwrap_or_else(|| json!(0)),
            "state": row.get("state").or_else(|| row.get("initial_state")).cloned().unwrap_or_else(|| json!("RECEIVED")),
            "reasonCode": row.get("reason_code").cloned().unwrap_or_else(|| json!("OTHER")),
            "requestedOutcome": row.get("requested_outcome").cloned().unwrap_or_else(|| json!("HUMAN_REVIEW")),
            "createdAt": row.get("created_at").cloned().unwrap_or(Value::Null),
            "updatedAt": row.get("created_at").cloned().unwrap_or(Value::Null),
            "dueAt": row.get("review_due_at").cloned().unwrap_or(Value::Null)
        }))
    }).collect())
}
