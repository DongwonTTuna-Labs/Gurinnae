use actix_web::{HttpResponse, http::StatusCode};
use gurine_auth::assertion::AssertionError;

use crate::service;

pub(super) fn service_problem(error: service::ServiceError) -> HttpResponse {
    let (code, status) = service_error_contract(&error);
    problem(code, status)
}

pub(super) fn service_error_contract(error: &service::ServiceError) -> (&'static str, u16) {
    match error {
        service::ServiceError::InvalidRequest => ("INVALID_REQUEST", 400),
        service::ServiceError::NotFound => ("RESOURCE_NOT_FOUND", 404),
        service::ServiceError::VersionConflict => ("VERSION_CONFLICT", 409),
        service::ServiceError::InvalidStateTransition => ("INVALID_STATE_TRANSITION", 409),
        service::ServiceError::PreconditionFailed => ("PRECONDITION_FAILED", 422),
        service::ServiceError::LegalHoldActive => ("LEGAL_HOLD_ACTIVE", 423),
        service::ServiceError::LegalHoldTargetUnsupported => ("LEGAL_HOLD_TARGET_UNSUPPORTED", 422),
        service::ServiceError::IdentityProofInvalid => ("IDENTITY_PROOF_INVALID", 403),
        service::ServiceError::PrivacyScopeInvalid => ("PRIVACY_SCOPE_INVALID", 422),
        service::ServiceError::PrivacyCorrectionTargetUnsupported => {
            ("PRIVACY_CORRECTION_TARGET_UNSUPPORTED", 422)
        }
        service::ServiceError::RetentionVersionConflict => ("RETENTION_VERSION_CONFLICT", 409),
        service::ServiceError::RetentionStateInvalid => ("RETENTION_STATE_INVALID", 409),
        service::ServiceError::BusinessCalendarStale => ("BUSINESS_CALENDAR_STALE", 409),
        service::ServiceError::DependencyUnavailable => ("DEPENDENCY_UNAVAILABLE", 503),
        service::ServiceError::CapabilityDenied => ("CAPABILITY_DENIED", 403),
        service::ServiceError::StepUpRequired => ("STEP_UP_REQUIRED", 403),
        service::ServiceError::ProposalRequired => ("ACTION_PROPOSAL_REQUIRED", 409),
        service::ServiceError::IdempotencyConflict => ("IDEMPOTENCY_CONFLICT", 409),
        service::ServiceError::Persistence => ("INTERNAL_ERROR", 500),
    }
}

pub(super) fn assertion_problem(error: AssertionError) -> HttpResponse {
    match error {
        AssertionError::Expired => problem("ACTOR_ASSERTION_EXPIRED", 401),
        AssertionError::AudienceMismatch => problem("ACTOR_ASSERTION_AUDIENCE_MISMATCH", 401),
        AssertionError::RequestMismatch => problem("ACTOR_ASSERTION_REQUEST_MISMATCH", 401),
        AssertionError::CapabilityDenied => problem("CAPABILITY_DENIED", 403),
        AssertionError::Replayed => problem("ACTOR_ASSERTION_REPLAYED", 409),
        _ => problem("ACTOR_ASSERTION_INVALID", 401),
    }
}

pub(super) fn problem(code: &str, status: u16) -> HttpResponse {
    let status_code = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status_code)
        .insert_header(("content-type", "application/problem+json"))
        .json(serde_json::json!({
            "code": code,
            "title": code,
            "status": status,
        }))
}
