use gurine_auth::{assertion::canonical::sha256_hex, envelope::encrypt};
use uuid::Uuid;

use super::{RequestContext, ServiceError, common::FIELD_PREFIX};

pub struct EncryptedFieldMaterial {
    pub ciphertext: Vec<u8>,
    pub aad_digest: String,
    pub encryption_key_id: String,
}

pub fn encrypt_field_material(
    context: &RequestContext<'_>,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    plaintext: &[u8],
) -> Result<EncryptedFieldMaterial, ServiceError> {
    let record_id = record_id.to_string();
    let aad_parts = [table, column, &record_id, logical_type, "1"];
    let ciphertext = encrypt(
        FIELD_PREFIX,
        &context.state.field_keys.current,
        &aad_parts,
        plaintext,
    )
    .map_err(|_| ServiceError::Cryptography)?;
    let encryption_key_id = envelope_key_id(&ciphertext)?;
    Ok(EncryptedFieldMaterial {
        ciphertext: ciphertext.into_bytes(),
        aad_digest: sha256_hex(aad_parts.join("\0").as_bytes()),
        encryption_key_id,
    })
}

fn envelope_key_id(ciphertext: &str) -> Result<String, ServiceError> {
    let mut segments = ciphertext.split('.');
    let prefix = segments.next();
    let key_id = segments.next();
    let nonce = segments.next();
    let body = segments.next();
    if prefix != Some(FIELD_PREFIX)
        || key_id.is_none_or(str::is_empty)
        || nonce.is_none_or(str::is_empty)
        || body.is_none_or(str::is_empty)
        || segments.next().is_some()
    {
        return Err(ServiceError::Cryptography);
    }
    key_id.map(str::to_owned).ok_or(ServiceError::Cryptography)
}
