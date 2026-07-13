use std::collections::BTreeSet;

use serde_json::Value;
use thiserror::Error;

pub struct ObjectSchema<'a> {
    pub required: &'a [&'a str],
    pub allowed: &'a [&'a str],
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum SchemaValidationError {
    #[error("agent output is not an object")]
    NotObject,
    #[error("agent output is missing a required field")]
    MissingRequiredField,
    #[error("agent output contains an undeclared field")]
    UnknownField,
}

pub fn validate_object(
    value: &Value,
    schema: ObjectSchema<'_>,
) -> Result<(), SchemaValidationError> {
    let object = value.as_object().ok_or(SchemaValidationError::NotObject)?;
    if schema
        .required
        .iter()
        .any(|name| !object.contains_key(*name))
    {
        return Err(SchemaValidationError::MissingRequiredField);
    }
    let allowed = schema.allowed.iter().copied().collect::<BTreeSet<_>>();
    if object.keys().any(|name| !allowed.contains(name.as_str())) {
        return Err(SchemaValidationError::UnknownField);
    }
    Ok(())
}
