use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RawSourceDocument {
    pub id: Uuid,
    pub source_id: String,
    pub object_key: String,
    pub media_type: String,
    pub sha256: String,
    pub fetched_at: OffsetDateTime,
    pub source_uri_hash: String,
}

impl RawSourceDocument {
    pub fn from_bytes(
        source_id: String,
        object_key: String,
        media_type: String,
        bytes: &[u8],
        fetched_at: OffsetDateTime,
        source_uri_hash: String,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            source_id,
            object_key,
            media_type,
            sha256: hex(&Sha256::digest(bytes)),
            fetched_at,
            source_uri_hash,
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
