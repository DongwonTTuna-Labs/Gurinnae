use super::*;

#[test]
fn privacy_transition_errors_keep_the_closed_problem_statuses() {
    for (error, expected) in [
        (
            service::ServiceError::IdentityProofInvalid,
            ("IDENTITY_PROOF_INVALID", 403),
        ),
        (
            service::ServiceError::PrivacyScopeInvalid,
            ("PRIVACY_SCOPE_INVALID", 422),
        ),
        (
            service::ServiceError::PrivacyCorrectionTargetUnsupported,
            ("PRIVACY_CORRECTION_TARGET_UNSUPPORTED", 422),
        ),
        (
            service::ServiceError::RetentionVersionConflict,
            ("RETENTION_VERSION_CONFLICT", 409),
        ),
        (
            service::ServiceError::RetentionStateInvalid,
            ("RETENTION_STATE_INVALID", 409),
        ),
        (
            service::ServiceError::BusinessCalendarStale,
            ("BUSINESS_CALENDAR_STALE", 409),
        ),
        (
            service::ServiceError::LegalHoldActive,
            ("LEGAL_HOLD_ACTIVE", 423),
        ),
        (
            service::ServiceError::LegalHoldTargetUnsupported,
            ("LEGAL_HOLD_TARGET_UNSUPPORTED", 422),
        ),
    ] {
        assert_eq!(service_error_contract(&error), expected);
    }
}

#[test]
fn idempotency_conflict_uses_the_authoritative_public_code() {
    assert_eq!(
        service_error_contract(&service::ServiceError::IdempotencyConflict),
        ("IDEMPOTENCY_CONFLICT", 409)
    );
}

#[test]
fn typed_step_up_error_uses_the_authoritative_public_code() {
    assert_eq!(
        service_error_contract(&service::ServiceError::StepUpRequired),
        ("STEP_UP_REQUIRED", 403)
    );
    assert_eq!(
        service_error_contract(&service::ServiceError::Persistence),
        ("INTERNAL_ERROR", 500),
        "unclassified persistence errors must remain fail-closed"
    );
}
