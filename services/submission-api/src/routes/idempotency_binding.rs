use actix_web::HttpRequest;
use gurine_api_contracts::OperationSpec;
use gurine_application::idempotency::{self, IdempotencyRequest};
use gurine_auth::assertion::canonical::canonical_request_digest;

use super::request_binding::{
    PrivacyIdempotencyError, bound_request, header, privacy_owner_idempotency,
};

pub(super) fn derive(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
) -> Result<IdempotencyRequest, IdempotencyBindingError> {
    let key = header(request, "idempotency-key").ok_or(IdempotencyBindingError::MissingKey)?;
    let bound = bound_request(request, body).map_err(|_| IdempotencyBindingError::Binding)?;
    let digest = canonical_request_digest(&bound).map_err(|_| IdempotencyBindingError::Binding)?;
    idempotency::request(operation.id, key, digest.as_bytes())
        .map_err(|_| IdempotencyBindingError::InvalidKey)
}

pub(super) fn derive_owner(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
) -> Result<IdempotencyRequest, IdempotencyBindingError> {
    if matches!(
        operation.id,
        "createPrivacyRequest" | "exchangePrivacyRequestReceiptToken"
    ) {
        return privacy_owner_idempotency(operation.id, request, body).map_err(
            |error| match error {
                PrivacyIdempotencyError::MissingKey => IdempotencyBindingError::MissingKey,
                PrivacyIdempotencyError::InvalidKey => IdempotencyBindingError::InvalidKey,
                PrivacyIdempotencyError::Binding | PrivacyIdempotencyError::InvalidOperation => {
                    IdempotencyBindingError::Binding
                }
            },
        );
    }
    derive(operation, request, body)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum IdempotencyBindingError {
    MissingKey,
    InvalidKey,
    Binding,
}
