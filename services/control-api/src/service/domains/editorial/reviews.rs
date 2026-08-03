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
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let response_id = uuid_value(payload, &["responseId"])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let request = response_excerpt_approval_request(payload, actor)?;
    let result = sqlx::query_scalar!(
        "SELECT editorial.approve_response_excerpt_guarded_v2($1)",
        request,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    owner_result_has_exact_keys(
        &result,
        &[
            "approvalId",
            "responseId",
            "responseVersion",
            "receiptDigest",
            "auditEventId",
            "approvedAt",
            "outboxEventIds",
            "replayed",
        ],
    )?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    required_owner_uuid(object, "approvalId")?;
    if required_owner_uuid(object, "responseId")? != response_id {
        return Err(ServiceError::Persistence);
    }
    parse_owner_command_receipt(
        operation,
        &result,
        response_id,
        "responseVersion",
        "approvedAt",
        &[],
    )
}

pub(super) async fn arm_submitreview(
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let snapshot =
        uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let snapshot_created_by = sqlx::query_scalar!(
        "SELECT created_by FROM editorial.review_snapshots WHERE id=$1",
        snapshot,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    if snapshot_created_by == actor {
        return Err(ServiceError::InvalidRequest);
    }
    reviews_named_person::record_review_stage(
        operation,
        payload,
        snapshot,
        snapshot_created_by,
        actor,
        tx,
    )
    .await
}

pub(super) async fn arm_verifyresponseorganizationidentity(
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let response_id = uuid_value(payload, &["responseId"])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let request = response_organization_identity_request(payload)?;
    let request_id = internal_uuid(payload, "_requestId")?;
    let idempotency_key_sha256 = internal_sha256(payload, "_idempotencyKeySha256")?;
    let request_sha256 = internal_sha256(payload, "_requestSha256")?;
    let result = sqlx::query_scalar!(
        "SELECT editorial.verify_response_organization_identity_v1($1,$2,$3,$4,$5)",
        request,
        actor,
        request_id,
        idempotency_key_sha256,
        request_sha256,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    validate_response_identity_owner_result(operation, &result, response_id)
}

fn response_organization_identity_request(
    payload: &Map<String, Value>,
) -> Result<Value, ServiceError> {
    let response_id = uuid_value(payload, &["responseId"])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let organization_id = uuid_value(payload, &["organizationId"])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let publication_form = match string_value(payload, "publicationForm") {
        Some(value @ ("FULL" | "REDACTED")) => value,
        _ => return Err(ServiceError::InvalidRequest),
    };
    let verification_method = match string_value(payload, "verificationMethod") {
        Some(value @ ("OFFICIAL_DOMAIN_EMAIL" | "OFFICIAL_DOCUMENT")) => value,
        _ => return Err(ServiceError::InvalidRequest),
    };
    let official_channel_assertion_id = uuid_value(payload, &["officialChannelSourceId"])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let reason = string_value(payload, "reason")
        .filter(|value| value.trim() == *value && (1..=4000).contains(&value.chars().count()))
        .ok_or(ServiceError::InvalidRequest)?;
    let expected_version = payload
        .get("expectedVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 1)
        .ok_or(ServiceError::InvalidRequest)?;
    let actor_assertion_jti = internal_uuid(payload, "_actorAssertionJti")?;
    let assurance_level = string_value(payload, "_actorAssuranceLevel")
        .filter(|value| *value == "STEP_UP")
        .ok_or(ServiceError::PreconditionFailed)?;
    let action_digest = internal_sha256(payload, "_actorActionDigest")?;
    let effective_capability =
        internal_capability(payload, "_actorEffectiveCapability", "responses.review")?;
    let step_up_authorization_id = internal_uuid(payload, "_actorStepUpAuthorizationId")?;
    let actor_idempotency_key_sha256 = internal_sha256(payload, "_actorIdempotencyKeySha256")?;
    let actor_request_key_sha256 = internal_sha256(payload, "_actorRequestKeySha256")?;
    Ok(json!({
        "responseId":response_id,
        "organizationId":organization_id,
        "publicationForm":publication_form,
        "verificationMethod":verification_method,
        "officialChannelSourceId":official_channel_assertion_id,
        "reason":reason,
        "expectedVersion":expected_version,
        "_actorAssertionJti":actor_assertion_jti,
        "_actorAssuranceLevel":assurance_level,
        "_actorEffectiveCapability":effective_capability,
        "_actorActionDigest":action_digest,
        "_actorStepUpAuthorizationId":step_up_authorization_id,
        "_actorIdempotencyKeySha256":actor_idempotency_key_sha256,
        "_actorRequestKeySha256":actor_request_key_sha256,
    }))
}

fn internal_uuid(payload: &Map<String, Value>, key: &str) -> Result<Uuid, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)
}

fn internal_sha256<'a>(
    payload: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a str, ServiceError> {
    string_value(payload, key)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)
}

fn internal_capability<'a>(
    payload: &'a Map<String, Value>,
    key: &str,
    expected: &str,
) -> Result<&'a str, ServiceError> {
    string_value(payload, key)
        .filter(|value| *value == expected)
        .ok_or(ServiceError::Persistence)
}

fn validate_response_identity_owner_result(
    operation: &str,
    result: &Value,
    response_id: Uuid,
) -> Result<OwnerCommandReceipt, ServiceError> {
    owner_result_has_exact_keys(
        result,
        &[
            "assertionId",
            "assertionVersion",
            "responseVersion",
            "receiptDigest",
            "auditEventId",
            "verifiedAt",
            "outboxEventIds",
            "replayed",
        ],
    )?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    required_owner_uuid(object, "assertionId")?;
    if object.get("assertionVersion").and_then(Value::as_i64) != Some(1) {
        return Err(ServiceError::Persistence);
    }
    parse_owner_command_receipt(
        operation,
        result,
        response_id,
        "responseVersion",
        "verifiedAt",
        &[("assertionId", "identityAssertionId")],
    )
}

fn response_excerpt_approval_request(
    payload: &Map<String, Value>,
    actor: Uuid,
) -> Result<Value, ServiceError> {
    let response_id = uuid_value(payload, &["responseId"])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let excerpt_hash = string_value(payload, "excerptHash")
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let publication_form = match string_value(payload, "publicationForm") {
        Some(value @ ("ANONYMOUS" | "FULL" | "REDACTED")) => value,
        _ => return Err(ServiceError::InvalidRequest),
    };
    let reason = string_value(payload, "reason")
        .filter(|value| value.trim() == *value && (1..=4000).contains(&value.chars().count()))
        .ok_or(ServiceError::InvalidRequest)?;
    let expected_version = payload
        .get("expectedVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 1)
        .ok_or(ServiceError::InvalidRequest)?;
    let actor_assertion_jti = internal_uuid(payload, "_actorAssertionJti")?;
    let assurance_level = match string_value(payload, "_actorAssuranceLevel") {
        Some(value @ ("ACTIVE_SESSION" | "STEP_UP")) => value,
        _ => return Err(ServiceError::PreconditionFailed),
    };
    let actor_request_key_sha256 = internal_sha256(payload, "_actorRequestKeySha256")?;
    let effective_capability =
        internal_capability(payload, "_actorEffectiveCapability", "responses.review")?;
    let request_id = internal_uuid(payload, "_requestId")?;
    let idempotency_key_sha256 = internal_sha256(payload, "_idempotencyKeySha256")?;
    let request_sha256 = internal_sha256(payload, "_requestSha256")?;
    Ok(json!({
        "responseId":response_id,
        "excerptHash":excerpt_hash,
        "publicationForm":publication_form,
        "reason":reason,
        "expectedVersion":expected_version,
        "_actorId":actor,
        "_actorAssertionJti":actor_assertion_jti,
        "_actorAssuranceLevel":assurance_level,
        "_actorEffectiveCapability":effective_capability,
        "_actorRequestKeySha256":actor_request_key_sha256,
        "_requestId":request_id,
        "_idempotencyKeySha256":idempotency_key_sha256,
        "_requestSha256":request_sha256,
    }))
}

#[cfg(test)]
#[path = "reviews_response_identity_tests.rs"]
mod r6d_response_identity_tests;
