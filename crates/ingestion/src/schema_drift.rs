use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SchemaMappingProposal {
    pub schema_drift_id: Uuid,
    pub mapping_version: i64,
    pub mapping: Value,
    pub mapping_digest: String,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum SchemaDriftError {
    #[error("schema mapping proposal is not canonical or has an invalid version")]
    InvalidProposal,
    #[error("schema mapping proposal version or digest conflicts")]
    Conflict,
}

impl SchemaMappingProposal {
    pub fn new(
        schema_drift_id: Uuid,
        mapping_version: i64,
        mapping: Value,
    ) -> Result<Self, SchemaDriftError> {
        if mapping_version < 1 || !mapping.is_object() {
            return Err(SchemaDriftError::InvalidProposal);
        }
        let bytes = serde_json::to_vec(&mapping).map_err(|_| SchemaDriftError::InvalidProposal)?;
        let mapping_digest = Sha256::digest(bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        Ok(Self {
            schema_drift_id,
            mapping_version,
            mapping,
            mapping_digest,
        })
    }

    pub fn matches(
        &self,
        schema_drift_id: Uuid,
        mapping_version: i64,
        mapping_digest: &str,
    ) -> bool {
        self.schema_drift_id == schema_drift_id
            && self.mapping_version == mapping_version
            && self.mapping_digest == mapping_digest
    }
}
