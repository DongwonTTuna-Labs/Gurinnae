use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Checkpoint {
    pub source_id: String,
    pub cursor: String,
    pub watermark: Option<String>,
    pub version: i64,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CheckpointError {
    #[error("checkpoint version conflicts")]
    VersionConflict,
    #[error("checkpoint cursor is empty")]
    EmptyCursor,
}

impl Checkpoint {
    pub fn advance(
        &mut self,
        cursor: String,
        watermark: Option<String>,
        expected_version: i64,
    ) -> Result<(), CheckpointError> {
        if self.version != expected_version {
            return Err(CheckpointError::VersionConflict);
        }
        if cursor.is_empty() {
            return Err(CheckpointError::EmptyCursor);
        }
        self.cursor = cursor;
        self.watermark = watermark;
        self.version += 1;
        Ok(())
    }
}
