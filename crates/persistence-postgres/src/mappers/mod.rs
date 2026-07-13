use thiserror::Error;

#[derive(Debug, Error)]
pub enum MappingError {
    #[error("database value is outside the domain contract")]
    InvalidDomainValue,
}

pub fn require_nonempty(value: String) -> Result<String, MappingError> {
    if value.trim().is_empty() {
        return Err(MappingError::InvalidDomainValue);
    }
    Ok(value)
}
