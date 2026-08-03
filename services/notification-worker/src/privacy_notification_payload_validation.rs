fn validate_identity_payload(
    binding: &PrivacyNotificationBinding,
    payload: &IdentityVerifiedPayload,
    template_due_at: &str,
    reason: &ReasonSealedFields,
    occurred_at: OffsetDateTime,
) -> Result<(), WorkerError> {
    let verified_at = parse_timestamp(&payload.identity_verified_at)?;
    let due_at = parse_timestamp(&payload.due_at)?;
    validate_common_payload(
        binding,
        payload.retention_request_id,
        payload.request_type,
        &payload.response_policy_version,
        &payload.response_policy_digest,
        payload.calendar_version_id,
        &payload.calendar_digest,
    )?;
    if payload.prior_identity_state != PrivacyIdentityState::PendingVerification
        || payload.identity_state != PrivacyIdentityState::Verified
        || binding.request.state != PrivacyRequestState::Received
        || binding.request.identity_state != PrivacyIdentityState::Verified
        || binding.request.identity_verified_at.as_deref()
            != Some(payload.identity_verified_at.as_str())
        || binding.request.due_at.as_deref() != Some(payload.due_at.as_str())
        || template_due_at != payload.due_at
        || verified_at > occurred_at
        || verified_at >= due_at
        || binding.transition.branch_receipt_digest != payload.verification_receipt_digest
    {
        return Err(WorkerError::Contract);
    }
    validate_sha256(&payload.identity_proof_receipt_digest)?;
    validate_sha256(&payload.verification_receipt_digest)?;
    validate_sealed_fields(reason.as_ref(), "reason", 10_000)
}

struct ExtensionTemplateRef<'a> {
    prior_due_at: &'a str,
    due_at: &'a str,
    extension_business_days: i64,
    reason_code: &'a str,
    reason: &'a ReasonSealedFields,
    extension_reason: &'a ExtensionReasonSealedFields,
}

fn validate_extension_payload(
    binding: &PrivacyNotificationBinding,
    payload: &ExtensionNotifiedPayload,
    template: ExtensionTemplateRef<'_>,
    occurred_at: OffsetDateTime,
) -> Result<(), WorkerError> {
    let prior_due_at = parse_timestamp(&payload.prior_due_at)?;
    let due_at = parse_timestamp(&payload.due_at)?;
    let notified_at = parse_timestamp(&payload.notified_at)?;
    validate_common_payload(
        binding,
        payload.retention_request_id,
        payload.request_type,
        &payload.response_policy_version,
        &payload.response_policy_digest,
        payload.calendar_version_id,
        &payload.calendar_digest,
    )?;
    if !matches!(
        binding.request.state,
        PrivacyRequestState::Received | PrivacyRequestState::Review | PrivacyRequestState::Approved
    ) || binding.request.identity_state != PrivacyIdentityState::Verified
        || binding.request.due_at.as_deref() != Some(payload.due_at.as_str())
        || payload.extension_sequence != 1
        || !(1..=10).contains(&payload.extension_business_days)
        || template.prior_due_at != payload.prior_due_at
        || template.due_at != payload.due_at
        || template.extension_business_days != payload.extension_business_days
        || prior_due_at >= due_at
        || notified_at > prior_due_at
        || notified_at > occurred_at
        || binding.transition.notice_receipt_digest != payload.notification_receipt_digest
    {
        return Err(WorkerError::Contract);
    }
    validate_bounded_text(template.reason_code, 100)?;
    validate_sha256(&payload.reason_digest)?;
    validate_sha256(&payload.notification_receipt_digest)?;
    validate_sealed_fields(template.reason.as_ref(), "reason", 10_000)?;
    validate_sealed_fields(template.extension_reason.as_ref(), "extensionReason", 4_000)?;
    if template.extension_reason.sha256 != payload.reason_digest {
        return Err(WorkerError::Contract);
    }
    Ok(())
}

struct RefusalTemplateRef<'a> {
    decision_at: &'a str,
    notice_due_at: &'a str,
    reason_code: &'a str,
    reason: &'a ReasonSealedFields,
    rejection_reason: &'a RejectionReasonSealedFields,
    appeal_instructions: &'a AppealInstructionsSealedFields,
}

fn validate_refusal_payload(
    binding: &PrivacyNotificationBinding,
    payload: &RefusalNotifiedPayload,
    template: RefusalTemplateRef<'_>,
    occurred_at: OffsetDateTime,
) -> Result<(), WorkerError> {
    let decision_at = parse_timestamp(&payload.decision_at)?;
    let notice_due_at = parse_timestamp(&payload.notice_due_at)?;
    let notified_at = parse_timestamp(&payload.notified_at)?;
    validate_common_payload(
        binding,
        payload.retention_request_id,
        payload.request_type,
        &payload.response_policy_version,
        &payload.response_policy_digest,
        payload.calendar_version_id,
        &payload.calendar_digest,
    )?;
    if binding.request.state != PrivacyRequestState::Rejected
        || binding.request.identity_state != PrivacyIdentityState::Verified
        || template.decision_at != payload.decision_at
        || template.notice_due_at != payload.notice_due_at
        || decision_at > notified_at
        || notified_at > notice_due_at
        || notified_at > occurred_at
        || binding.transition.notice_receipt_digest != payload.notification_receipt_digest
    {
        return Err(WorkerError::Contract);
    }
    validate_bounded_text(template.reason_code, 100)?;
    for digest in [
        &payload.decision_digest,
        &payload.reason_digest,
        &payload.appeal_instructions_digest,
        &payload.notification_receipt_digest,
    ] {
        validate_sha256(digest)?;
    }
    validate_sealed_fields(template.reason.as_ref(), "reason", 10_000)?;
    validate_sealed_fields(template.rejection_reason.as_ref(), "rejectionReason", 4_000)?;
    validate_sealed_fields(
        template.appeal_instructions.as_ref(),
        "appealInstructions",
        4_000,
    )?;
    if template.rejection_reason.sha256 != payload.reason_digest
        || template.appeal_instructions.sha256 != payload.appeal_instructions_digest
    {
        return Err(WorkerError::Contract);
    }
    Ok(())
}

fn validate_common_payload(
    binding: &PrivacyNotificationBinding,
    request_id: Uuid,
    request_type: PrivacyRequestType,
    policy_version: &str,
    policy_digest: &str,
    calendar_version_id: Uuid,
    calendar_digest: &str,
) -> Result<(), WorkerError> {
    if request_id.is_nil()
        || request_id != binding.request.retention_request_id
        || request_type != binding.request.request_type
        || calendar_version_id.is_nil()
    {
        return Err(WorkerError::Contract);
    }
    validate_bounded_text(policy_version, 10_000)?;
    validate_sha256(policy_digest)?;
    validate_sha256(calendar_digest)
}
