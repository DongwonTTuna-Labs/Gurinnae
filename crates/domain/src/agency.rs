use serde::{Deserialize, Serialize};

use crate::{
    error::{DomainError, validated_text},
    ids::AgencyId,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Agency {
    pub id: AgencyId,
    pub canonical_name: String,
    pub government_code: Option<String>,
    pub active: bool,
}

impl Agency {
    pub fn new(
        id: AgencyId,
        canonical_name: impl Into<String>,
        government_code: Option<String>,
    ) -> Result<Self, DomainError> {
        let canonical_name = validated_text(canonical_name, 300)?;
        if government_code
            .as_ref()
            .is_some_and(|code| code.trim().is_empty() || code.len() > 100)
        {
            return Err(DomainError::InvalidIdentifier);
        }
        Ok(Self {
            id,
            canonical_name,
            government_code,
            active: true,
        })
    }
}
