use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum AssertionError {
    #[error("assertion format is invalid")]
    FormatInvalid,
    #[error("assertion key id is unknown")]
    UnknownKey,
    #[error("assertion payload is not canonical")]
    NoncanonicalPayload,
    #[error("assertion signature is invalid")]
    SignatureInvalid,
    #[error("assertion payload does not match its schema")]
    SchemaInvalid,
    #[error("assertion was issued in the future")]
    IssuedInFuture,
    #[error("assertion has expired")]
    Expired,
    #[error("assertion audience does not match")]
    AudienceMismatch,
    #[error("assertion request binding does not match")]
    RequestMismatch,
    #[error("actor does not hold the required capability")]
    CapabilityDenied,
    #[error("assertion has already been consumed")]
    Replayed,
    #[error("replay guard is unavailable")]
    ReplayGuardUnavailable,
}
