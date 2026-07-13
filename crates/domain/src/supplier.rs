use serde::{Deserialize, Serialize};

use crate::{
    error::{DomainError, validated_text},
    ids::SupplierId,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Supplier {
    pub id: SupplierId,
    pub canonical_name: String,
    pub registration_number_hash: Option<String>,
    pub active: bool,
}

impl Supplier {
    pub fn new(
        id: SupplierId,
        canonical_name: impl Into<String>,
        registration_number_hash: Option<String>,
    ) -> Result<Self, DomainError> {
        let canonical_name = validated_text(canonical_name, 300)?;
        if registration_number_hash
            .as_ref()
            .is_some_and(|hash| !is_hash(hash))
        {
            return Err(DomainError::InvalidIdentifier);
        }
        Ok(Self {
            id,
            canonical_name,
            registration_number_hash,
            active: true,
        })
    }
}

fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
