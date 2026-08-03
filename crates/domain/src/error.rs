use thiserror::Error;

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DomainError {
    #[error("required value is empty")]
    EmptyValue,
    #[error("value exceeds the domain length limit")]
    ValueTooLong,
    #[error("identifier is invalid")]
    InvalidIdentifier,
    #[error("currency is invalid")]
    InvalidCurrency,
    #[error("monetary amount is invalid")]
    InvalidAmount,
    #[error("time range is invalid")]
    InvalidTimeRange,
    #[error("domain transition is invalid")]
    InvalidTransition,
    #[error("expected aggregate version does not match")]
    VersionConflict,
    #[error("required human approval is absent")]
    HumanApprovalRequired,
    #[error("evidence is not revision-fixed or verified")]
    EvidenceNotPublishable,
}

pub fn validated_text(
    value: impl Into<String>,
    maximum_chars: usize,
) -> Result<String, DomainError> {
    let value = value.into();
    if value.trim().is_empty() {
        return Err(DomainError::EmptyValue);
    }
    if value.chars().count() > maximum_chars {
        return Err(DomainError::ValueTooLong);
    }
    Ok(value)
}
