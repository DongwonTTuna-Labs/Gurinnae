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
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Option<OwnerCommandReceipt>, ServiceError> {
    reject_caller_publication_guard_authority(payload)?;
    let resolution = parse_correction_resolution(payload)?;
    if resolution.is_resolved() {
        return resolve_correction_with_publication(
            operation,
            payload,
            &resolution,
            actor,
            field_keys,
            tx,
        )
        .await
        .map(Some);
    }
    persist_non_publication_resolution(&resolution, tx).await?;

    Ok(None)
}

struct CorrectionResolution<'a> {
    correction_id: Uuid,
    resolution: &'a str,
    reason: &'a str,
    expected_version: i64,
}

impl CorrectionResolution<'_> {
    fn is_resolved(&self) -> bool {
        self.resolution == "RESOLVED"
    }
}

fn parse_correction_resolution(
    payload: &Map<String, Value>,
) -> Result<CorrectionResolution<'_>, ServiceError> {
    let correction_id =
        uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
    let resolution = string_value(payload, "resolution").ok_or(ServiceError::InvalidRequest)?;
    if !matches!(
        resolution,
        "RESOLVED" | "REJECTED" | "DUPLICATE" | "WITHDRAWN"
    ) {
        return Err(ServiceError::InvalidRequest);
    }
    let reason = string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?;
    let expected_version = payload
        .get("expectedVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 1)
        .ok_or(ServiceError::InvalidRequest)?;
    Ok(CorrectionResolution {
        correction_id,
        resolution,
        reason,
        expected_version,
    })
}

async fn resolve_correction_with_publication(
    operation: &str,
    payload: &Map<String, Value>,
    resolution: &CorrectionResolution<'_>,
    actor: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let public_payload = sqlx::query_scalar!(
        "SELECT editorial.build_corrected_publication_payload_v2($1,$2,$3)",
        resolution.correction_id,
        resolution.expected_version,
        resolution.reason,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let public_payload_sha256 = canonical_json_digest(&public_payload)?;
    let scan = scan_publication_payload(&public_payload, field_keys, tx).await?;
    let scan_payload = publication_scan_payload(&scan)?;
    let mut request = super::publication::owner_authority_request(payload, actor)?;
    request.extend([
        ("mode".to_owned(), json!("CORRECTION")),
        ("correctionId".to_owned(), json!(resolution.correction_id)),
        ("resolution".to_owned(), json!(resolution.resolution)),
        ("reason".to_owned(), json!(resolution.reason)),
        (
            "expectedVersion".to_owned(),
            json!(resolution.expected_version),
        ),
        (
            "publicPayloadSha256".to_owned(),
            json!(&public_payload_sha256),
        ),
        ("scan".to_owned(), scan_payload),
    ]);
    let result = sqlx::query_scalar!(
        "SELECT editorial.publish_guarded_revision_v2($1)",
        Value::Object(request),
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    validate_resolved_correction_owner_result(
        &result,
        resolution.correction_id,
        resolution.expected_version,
        &public_payload_sha256,
    )?;
    parse_owner_command_receipt(
        operation,
        &result,
        resolution.correction_id,
        "correctionVersion",
        "resolvedAt",
        &[],
    )
}

async fn persist_non_publication_resolution(
    resolution: &CorrectionResolution<'_>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query!(
        "UPDATE editorial.corrections SET resolution=$2,resolution_reason=$3, \
         resolved_at=clock_timestamp(),status='REJECTED' \
         WHERE id=$1 AND status='REVIEW' AND version=$4::bigint+1",
        resolution.correction_id,
        resolution.resolution,
        resolution.reason,
        resolution.expected_version,
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
        resolution.correction_id,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

fn validate_resolved_correction_owner_result(
    result: &Value,
    correction_id: Uuid,
    expected_version: i64,
    public_payload_sha256: &str,
) -> Result<(), ServiceError> {
    owner_result_has_exact_keys(
        result,
        &[
            "correctionId",
            "correctionVersion",
            "caseId",
            "caseVersion",
            "reviewSnapshotId",
            "revisionId",
            "revision",
            "publicationState",
            "assessmentId",
            "assessmentDigest",
            "publicPayloadSha256",
            "resolvedAt",
            "receiptDigest",
            "auditEventId",
            "outboxEventIds",
            "replayed",
        ],
    )?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    if required_owner_uuid(object, "correctionId")? != correction_id
        || required_owner_uuid(object, "caseId").is_err()
        || required_owner_uuid(object, "reviewSnapshotId").is_err()
        || required_owner_uuid(object, "revisionId").is_err()
        || required_owner_uuid(object, "assessmentId").is_err()
        || object.get("correctionVersion").and_then(Value::as_i64)
            != expected_version.checked_add(1)
        || !object
            .get("caseVersion")
            .and_then(Value::as_i64)
            .is_some_and(|value| value >= 1)
        || !object
            .get("revision")
            .and_then(Value::as_i64)
            .is_some_and(|value| value >= 1)
        || object.get("publicationState").and_then(Value::as_str) != Some("CORRECTED")
        || object.get("publicPayloadSha256").and_then(Value::as_str) != Some(public_payload_sha256)
        || !object
            .get("assessmentDigest")
            .and_then(Value::as_str)
            .is_some_and(is_sha256)
    {
        return Err(ServiceError::Persistence);
    }
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
