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
    let exists: bool = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM editorial.publication_revisions WHERE id=$1)",
        publication,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    if !exists {
        return Err(ServiceError::NotFound);
    }
    sqlx::query!(
        "INSERT INTO editorial.retraction_drafts(id,publication_revision_id,scope, \
         affected_claim_ids,reason,status,created_by) VALUES($1,$2,$3,$4,$5,'DRAFT',$6)",
        id,
        publication,
        scope,
        payload
            .get("affectedClaimIds")
            .cloned()
            .unwrap_or_else(|| json!([])),
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_previewpublication(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    reject_caller_publication_guard_authority(payload)?;
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let snapshot =
        uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let locale = string_value(payload, "locale").ok_or(ServiceError::InvalidRequest)?;
    let expected_version = sqlx::query_scalar!(
        "SELECT c.version FROM editorial.cases c \
         JOIN editorial.review_snapshots s ON s.id=$2 AND s.case_id=c.id \
         WHERE c.id=$1 AND c.current_review_snapshot_id=s.id \
           AND s.case_version=c.version",
        case_id,
        snapshot,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::VersionConflict)?;
    let mut public_payload = publication_payload(case_id, snapshot, tx).await?;
    bind_preview_publication_contract(&mut public_payload, payload)?;
    let publication_state = public_payload
        .get("publicationState")
        .and_then(Value::as_str)
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let public_payload_sha256 = canonical_json_digest(&public_payload)?;
    let scan = scan_publication_payload(&public_payload, field_keys, tx).await?;
    let scan_payload = publication_scan_payload(&scan)?;
    let mut request = owner_authority_request(payload, actor)?;
    request.extend([
        ("previewId".to_owned(), json!(id)),
        ("caseId".to_owned(), json!(case_id)),
        ("reviewSnapshotId".to_owned(), json!(snapshot)),
        ("expectedVersion".to_owned(), json!(expected_version)),
        ("publicationState".to_owned(), json!(&publication_state)),
        ("locale".to_owned(), json!(locale)),
        ("publicPayload".to_owned(), public_payload),
        (
            "publicPayloadSha256".to_owned(),
            json!(&public_payload_sha256),
        ),
        ("scan".to_owned(), scan_payload),
        ("legalOverride".to_owned(), Value::Null),
    ]);
    let result = sqlx::query_scalar!(
        "SELECT editorial.preview_publication_guarded_v2($1)",
        Value::Object(request),
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    validate_preview_owner_result(
        &result,
        id,
        case_id,
        snapshot,
        expected_version,
        &publication_state,
        &public_payload_sha256,
        &scan,
    )?;
    parse_owner_command_receipt(operation, &result, id, "caseVersion", "createdAt", &[])
}

pub(super) async fn arm_publishcase(
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    reject_caller_publication_guard_authority(payload)?;
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let snapshot =
        uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let preview_hash = string_value(payload, "previewHash")
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let expected_version = payload
        .get("expectedVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 1)
        .ok_or(ServiceError::InvalidRequest)?;
    let reason = string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?;
    let preview = sqlx::query!(
        "SELECT preview_payload,btrim(preview_sha256::text) AS \"preview_sha256!\" \
         FROM editorial.publication_previews \
         WHERE case_id=$1 AND review_snapshot_id=$2 AND preview_sha256=$3 \
           AND expires_at>clock_timestamp() ORDER BY created_at DESC LIMIT 1",
        case_id,
        snapshot,
        preview_hash,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::InvalidRequest)?;
    let public_payload_sha256 = canonical_json_digest(&preview.preview_payload)?;
    if preview.preview_sha256 != preview_hash || public_payload_sha256 != preview_hash {
        return Err(ServiceError::PreconditionFailed);
    }
    let scan = scan_publication_payload(&preview.preview_payload, field_keys, tx).await?;
    let scan_payload = publication_scan_payload(&scan)?;
    let mut request = owner_authority_request(payload, actor)?;
    request.extend([
        ("mode".to_owned(), json!("PUBLISH")),
        ("caseId".to_owned(), json!(case_id)),
        ("reviewSnapshotId".to_owned(), json!(snapshot)),
        ("expectedVersion".to_owned(), json!(expected_version)),
        ("previewHash".to_owned(), json!(preview_hash)),
        ("reason".to_owned(), json!(reason)),
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
    validate_publish_owner_result(
        &result,
        case_id,
        snapshot,
        expected_version,
        preview_hash,
        &public_payload_sha256,
    )?;
    parse_owner_command_receipt(
        operation,
        &result,
        case_id,
        "caseVersion",
        "publishedAt",
        &[],
    )
}

pub(super) fn owner_authority_request(
    payload: &Map<String, Value>,
    actor: Uuid,
) -> Result<Map<String, Value>, ServiceError> {
    const KEYS: [&str; 10] = [
        "_actorAssertionJti",
        "_actorAssuranceLevel",
        "_actorEffectiveCapability",
        "_actorActionDigest",
        "_actorStepUpAuthorizationId",
        "_actorIdempotencyKeySha256",
        "_actorRequestKeySha256",
        "_requestId",
        "_idempotencyKeySha256",
        "_requestSha256",
    ];
    let mut request = Map::from_iter([("_actorId".to_owned(), json!(actor))]);
    for key in KEYS {
        request.insert(
            key.to_owned(),
            payload.get(key).cloned().ok_or(ServiceError::Persistence)?,
        );
    }
    Ok(request)
}

#[expect(
    clippy::too_many_arguments,
    reason = "preview owner output is checked against every server-derived authority"
)]
fn validate_preview_owner_result(
    result: &Value,
    preview_id: Uuid,
    case_id: Uuid,
    snapshot_id: Uuid,
    expected_version: i64,
    publication_state: &str,
    public_payload_sha256: &str,
    scan: &PublicationScan,
) -> Result<(), ServiceError> {
    owner_result_has_exact_keys(
        result,
        &[
            "previewId",
            "caseId",
            "caseVersion",
            "reviewSnapshotId",
            "assessmentId",
            "assessmentDigest",
            "assessmentReceiptDigest",
            "previewSha256",
            "publicationState",
            "publicTextSha256",
            "registeredNameSetSha256",
            "legalReviewRequired",
            "status",
            "createdAt",
            "expiresAt",
            "receiptDigest",
            "auditEventId",
            "outboxEventIds",
            "replayed",
        ],
    )?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    if required_owner_uuid(object, "previewId")? != preview_id
        || required_owner_uuid(object, "caseId")? != case_id
        || required_owner_uuid(object, "reviewSnapshotId")? != snapshot_id
        || object.get("caseVersion").and_then(Value::as_i64) != Some(expected_version)
        || object.get("publicationState").and_then(Value::as_str) != Some(publication_state)
        || object.get("previewSha256").and_then(Value::as_str) != Some(public_payload_sha256)
        || object.get("publicTextSha256").and_then(Value::as_str)
            != Some(scan.assessment.public_text_sha256.as_str())
        || object
            .get("registeredNameSetSha256")
            .and_then(Value::as_str)
            != Some(scan.registered_name_set_sha256.as_str())
        || !object
            .get("assessmentDigest")
            .and_then(Value::as_str)
            .is_some_and(is_sha256)
        || !object
            .get("assessmentReceiptDigest")
            .and_then(Value::as_str)
            .is_some_and(is_sha256)
        || required_owner_uuid(object, "assessmentId").is_err()
        || !matches!(
            object.get("status").and_then(Value::as_str),
            Some("READY" | "BLOCKED")
        )
        || !object
            .get("legalReviewRequired")
            .is_some_and(Value::is_boolean)
    {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

fn validate_publish_owner_result(
    result: &Value,
    case_id: Uuid,
    snapshot_id: Uuid,
    expected_version: i64,
    preview_hash: &str,
    public_payload_sha256: &str,
) -> Result<(), ServiceError> {
    owner_result_has_exact_keys(
        result,
        &[
            "caseId",
            "caseVersion",
            "reviewSnapshotId",
            "revisionId",
            "revision",
            "publicationState",
            "assessmentId",
            "assessmentDigest",
            "previewSha256",
            "publicPayloadSha256",
            "publishedAt",
            "receiptDigest",
            "auditEventId",
            "outboxEventIds",
            "replayed",
        ],
    )?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    if required_owner_uuid(object, "caseId")? != case_id
        || required_owner_uuid(object, "reviewSnapshotId")? != snapshot_id
        || required_owner_uuid(object, "revisionId").is_err()
        || required_owner_uuid(object, "assessmentId").is_err()
        || object.get("caseVersion").and_then(Value::as_i64) != expected_version.checked_add(1)
        || !object
            .get("revision")
            .and_then(Value::as_i64)
            .is_some_and(|value| value >= 1)
        || object.get("previewSha256").and_then(Value::as_str) != Some(preview_hash)
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
