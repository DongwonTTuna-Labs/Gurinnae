use actix_web::HttpResponse;

use crate::service::ServiceError;

use super::problem;

pub(super) fn service_problem(error: ServiceError, request_id: &str) -> HttpResponse {
    let (code, status) = match error {
        ServiceError::InvalidRequest => ("INVALID_REQUEST", 400),
        ServiceError::InvalidParameter => ("INVALID_PARAMETER", 400),
        ServiceError::TokenInvalid => ("ONE_TIME_TOKEN_INVALID", 401),
        ServiceError::InvalidSession => ("SUBMISSION_SESSION_INVALID", 401),
        ServiceError::NotFound => ("RESOURCE_NOT_FOUND", 404),
        ServiceError::Conflict => ("OPTIMISTIC_CONCURRENCY_CONFLICT", 409),
        ServiceError::Closed => ("RESOURCE_CLOSED", 409),
        ServiceError::AbuseProofInvalid => ("ABUSE_PROOF_INVALID", 403),
        ServiceError::AbuseProofUnavailable => ("ABUSE_PROOF_UNAVAILABLE", 503),
        ServiceError::IdentityProofInvalid => ("IDENTITY_PROOF_INVALID", 403),
        ServiceError::PrivacyScopeInvalid => ("PRIVACY_SCOPE_INVALID", 422),
        ServiceError::PrivacyTokenInvalid => ("TOKEN_INVALID", 401),
        ServiceError::PrivacyTokenExpired => ("TOKEN_EXPIRED", 401),
        ServiceError::PrivacyTokenReplayed => ("TOKEN_REPLAYED", 409),
        ServiceError::ScopedSessionRequired => ("SCOPED_SESSION_REQUIRED", 401),
        ServiceError::IdempotencyConflict => ("IDEMPOTENCY_CONFLICT", 409),
        ServiceError::PrivacyVoiceConsentAuthorityMissing => ("PRECONDITION_FAILED", 412),
        ServiceError::EndpointVerificationAuthorityIncomplete => ("INTERNAL_ERROR", 500),
        ServiceError::Persistence => ("DEPENDENCY_UNAVAILABLE", 503),
        ServiceError::Cryptography => ("CRYPTOGRAPHIC_OPERATION_FAILED", 500),
    };
    problem(code, status, request_id)
}

#[cfg(test)]
mod tests {
    use actix_web::{body::to_bytes, http::StatusCode};
    use serde_json::json;

    use super::{ServiceError, service_problem};

    #[test]
    fn privacy_authorization_and_replay_errors_keep_catalog_statuses() {
        let cases = [
            (ServiceError::IdentityProofInvalid, StatusCode::FORBIDDEN),
            (
                ServiceError::PrivacyScopeInvalid,
                StatusCode::UNPROCESSABLE_ENTITY,
            ),
            (ServiceError::PrivacyTokenInvalid, StatusCode::UNAUTHORIZED),
            (ServiceError::PrivacyTokenExpired, StatusCode::UNAUTHORIZED),
            (ServiceError::PrivacyTokenReplayed, StatusCode::CONFLICT),
            (
                ServiceError::ScopedSessionRequired,
                StatusCode::UNAUTHORIZED,
            ),
            (
                ServiceError::PrivacyVoiceConsentAuthorityMissing,
                StatusCode::PRECONDITION_FAILED,
            ),
        ];
        for (error, expected) in cases {
            assert_eq!(service_problem(error, "request-id").status(), expected);
        }
    }

    #[actix_web::test]
    async fn endpoint_authority_gap_returns_only_the_allowed_internal_error() {
        const RAW_PROOF: &str = "raw-email-link-proof-must-never-leak-0001";
        let response = service_problem(
            ServiceError::EndpointVerificationAuthorityIncomplete,
            "request-id",
        );
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(
            response
                .headers()
                .get("x-request-id")
                .and_then(|v| v.to_str().ok()),
            Some("request-id")
        );
        let bytes = match to_bytes(response.into_body()).await {
            Ok(value) => value,
            Err(_) => {
                panic!("problem response body must be readable");
            }
        };
        let body = match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(value) => value,
            Err(_) => {
                panic!("problem response body must be JSON");
            }
        };
        assert_eq!(
            body,
            json!({
                "code": "INTERNAL_ERROR",
                "title": "INTERNAL_ERROR",
                "status": 500,
                "requestId": "request-id"
            })
        );
        assert!(!String::from_utf8_lossy(&bytes).contains(RAW_PROOF));
    }
}
