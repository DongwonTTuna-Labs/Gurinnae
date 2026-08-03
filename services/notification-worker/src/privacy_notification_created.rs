#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreatedPrivacyNotificationBinding {
    schema_version: String,
    notice_type: PrivacyNoticeType,
    event: PrivacyNotificationEventBinding,
    request: PrivacyNotificationRequestBinding,
    endpoint: PrivacyNotificationEndpointBinding,
    template: CreatedPrivacyNoticeTemplate,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "SCREAMING_SNAKE_CASE", deny_unknown_fields)]
enum CreatedPrivacyNoticeTemplate {
    IdentityVerificationRequired,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PrivacyRequestCreatedPayload {
    retention_request_id: Uuid,
    request_type: PrivacyRequestType,
    subject_proof_hash: String,
    jurisdiction: String,
    scope_digest: String,
    identity_state: PrivacyIdentityState,
    // Unit fields make both keys required and accept JSON null only.
    identity_verified_at: (),
    due_at: (),
    receipt_digest: String,
    command_receipt_digest: String,
}

fn validate_created_privacy_notification(
    event: &ClaimedEvent,
    value: serde_json::Value,
) -> Result<ValidatedPrivacyNotification, WorkerError> {
    let binding: CreatedPrivacyNotificationBinding =
        serde_json::from_value(value).map_err(|_| WorkerError::Contract)?;
    validate_privacy_notification_common(
        event,
        &binding.schema_version,
        &binding.event,
        &binding.request,
        &binding.endpoint,
    )?;
    let payload: PrivacyRequestCreatedPayload =
        serde_json::from_value(event.payload.clone()).map_err(|_| WorkerError::Contract)?;
    if binding.notice_type != PrivacyNoticeType::IdentityVerificationRequired
        || !matches!(
            binding.template,
            CreatedPrivacyNoticeTemplate::IdentityVerificationRequired
        )
        || event.aggregate_version != 1
        || binding.request.state != PrivacyRequestState::Received
        || binding.request.decision_version != 0
        || binding.request.identity_state != PrivacyIdentityState::PendingVerification
        || binding.request.identity_verified_at.is_some()
        || binding.request.due_at.is_some()
        || binding.endpoint.state != "PENDING_VERIFICATION"
        || payload.retention_request_id != binding.request.retention_request_id
        || payload.request_type != binding.request.request_type
        || payload.identity_state != PrivacyIdentityState::PendingVerification
    {
        return Err(WorkerError::Contract);
    }
    let _required_nulls = (payload.identity_verified_at, payload.due_at);
    validate_bounded_text(&payload.jurisdiction, 10_000)?;
    for digest in [
        &payload.subject_proof_hash,
        &payload.scope_digest,
        &payload.receipt_digest,
        &payload.command_receipt_digest,
    ] {
        validate_sha256(digest)?;
    }
    Ok(ValidatedPrivacyNotification {
        notice_type: PrivacyNoticeType::IdentityVerificationRequired,
        request_type: binding.request.request_type,
        retention_request_id: binding.request.retention_request_id,
        event_envelope_digest: binding.event.event_envelope_digest,
        transition_receipt_id: None,
        endpoint: binding.endpoint,
        template: PrivacyNoticeTemplate::IdentityVerificationRequired,
    })
}

fn validate_privacy_notification_common(
    event: &ClaimedEvent,
    schema_version: &str,
    binding_event: &PrivacyNotificationEventBinding,
    request: &PrivacyNotificationRequestBinding,
    endpoint: &PrivacyNotificationEndpointBinding,
) -> Result<OffsetDateTime, WorkerError> {
    if schema_version != PRIVACY_NOTIFICATION_SCHEMA
        || binding_event.event_id != event.id
        || binding_event.event_type != event.event_type
        || binding_event.aggregate_id != event.aggregate_id
        || binding_event.aggregate_version != event.aggregate_version
        || binding_event.payload != event.payload
        || request.retention_request_id != event.aggregate_id
        || endpoint.version < 1
        || binding_event.event_id.is_nil()
        || binding_event.aggregate_id.is_nil()
        || endpoint.endpoint_id.is_nil()
    {
        return Err(WorkerError::Contract);
    }
    match (
        request.identity_state,
        request.identity_verified_at.as_deref(),
        request.due_at.as_deref(),
    ) {
        (PrivacyIdentityState::PendingVerification, None, None) => {}
        (PrivacyIdentityState::Verified, Some(verified_at), Some(due_at)) => {
            if parse_timestamp(verified_at)? >= parse_timestamp(due_at)? {
                return Err(WorkerError::Contract);
            }
        }
        _ => return Err(WorkerError::Contract),
    }
    for digest in [
        &binding_event.event_envelope_digest,
        &endpoint.endpoint_digest,
        &endpoint.endpoint_aad_digest,
    ] {
        validate_sha256(digest)?;
    }
    validate_bounded_text(&endpoint.encryption_key_id, 200)?;
    let occurred_at = parse_timestamp(&binding_event.occurred_at)?;
    if parse_timestamp(&endpoint.updated_at)? > occurred_at {
        return Err(WorkerError::Contract);
    }
    validate_endpoint_ciphertext(endpoint)?;
    Ok(occurred_at)
}
