use time::OffsetDateTime;
use uuid::Uuid;

use crate::port::{ObjectStoreClient, ObjectStoreError};

pub async fn quarantine(
    store: &ObjectStoreClient,
    source_key: &str,
    reason_code: &str,
    now: OffsetDateTime,
) -> Result<String, ObjectStoreError> {
    let safe_reason = reason_code
        .chars()
        .filter(|character| {
            character.is_ascii_uppercase() || character.is_ascii_digit() || *character == '_'
        })
        .collect::<String>();
    if safe_reason.is_empty() || safe_reason != reason_code {
        return Err(ObjectStoreError::InvalidKey);
    }
    let destination = format!("quarantine/{}/{safe_reason}/{}", now.date(), Uuid::new_v4());
    store.move_object(source_key, &destination).await?;
    Ok(destination)
}
