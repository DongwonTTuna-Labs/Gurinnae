use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct FieldProvenance {
    pub source_document_id: Uuid,
    pub parser_run_id: Uuid,
    pub locator_kind: String,
    pub locator_value: String,
    pub source_value_sha256: String,
    pub transformation: String,
}

impl FieldProvenance {
    pub fn is_valid(&self) -> bool {
        !self.locator_kind.is_empty()
            && !self.locator_value.is_empty()
            && self.source_value_sha256.len() == 64
            && self
                .source_value_sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
            && !self.transformation.is_empty()
    }
}
