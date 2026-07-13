use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SnapshotError {
    #[error("snapshot serialization failed")]
    Serialization,
}

pub fn digest<T: Serialize>(snapshot: &T) -> Result<String, SnapshotError> {
    let value = serde_json::to_value(snapshot).map_err(|_| SnapshotError::Serialization)?;
    let bytes = serde_json::to_vec(&value).map_err(|_| SnapshotError::Serialization)?;
    Ok(Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}
