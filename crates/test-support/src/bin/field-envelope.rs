use std::{env, io};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use gurine_auth::envelope::{EnvelopeKey, encrypt};

fn main() -> io::Result<()> {
    let key = required("FIELD_KEY_BASE64")?;
    let key: [u8; 32] = STANDARD
        .decode(key)
        .map_err(io::Error::other)?
        .try_into()
        .map_err(|_| io::Error::other("field key must be exactly 32 bytes"))?;
    let table = required("FIELD_TABLE")?;
    let column = required("FIELD_COLUMN")?;
    let record_id = required("FIELD_RECORD_ID")?;
    let logical_type = required("FIELD_LOGICAL_TYPE")?;
    let plaintext = required("FIELD_PLAINTEXT")?;
    let token = encrypt(
        "gurine-fe-v1",
        &EnvelopeKey::new(key),
        &[&table, &column, &record_id, &logical_type, "1"],
        plaintext.as_bytes(),
    )
    .map_err(io::Error::other)?;
    println!("{token}");
    Ok(())
}

fn required(name: &'static str) -> io::Result<String> {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| io::Error::other(format!("missing {name}")))
}
