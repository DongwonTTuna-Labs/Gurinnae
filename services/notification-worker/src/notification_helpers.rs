fn decrypt_email(
    state: &State,
    table: &str,
    column: &str,
    id: Uuid,
    ciphertext: &[u8],
) -> Result<String, WorkerError> {
    let token = std::str::from_utf8(ciphertext).map_err(|_| WorkerError::Cryptography)?;
    let id_text = id.to_string();
    let bytes = decrypt(
        "gurine-fe-v1",
        &state.field_keys,
        &[table, column, &id_text, "email-address", "1"],
        token,
    )
    .map_err(|_| WorkerError::Cryptography)?;
    String::from_utf8(bytes).map_err(|_| WorkerError::Cryptography)
}

fn random_token() -> Result<String, WorkerError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| WorkerError::Cryptography)?;
    let value = URL_SAFE_NO_PAD.encode(bytes);
    bytes.zeroize();
    Ok(value)
}
fn token_hmac(key: &[u8], token: &str) -> Result<String, WorkerError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| WorkerError::Cryptography)?;
    mac.update(token.as_bytes());
    Ok(mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn derived_token(key: &[u8], purpose: &str, id: Uuid) -> Result<String, WorkerError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| WorkerError::Cryptography)?;
    mac.update(purpose.as_bytes());
    mac.update(b":");
    mac.update(id.as_bytes());
    Ok(URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

fn response_otp(key: &[u8], access_token_hash: &str) -> Result<String, WorkerError> {
    let digest = token_hmac(key, &format!("response-otp:{access_token_hash}"))?;
    let prefix = digest.get(..8).ok_or(WorkerError::Cryptography)?;
    let value = u32::from_str_radix(prefix, 16).map_err(|_| WorkerError::Cryptography)?;
    Ok(format!("{:06}", value % 1_000_000))
}

async fn mark_failed(state: &State, id: Uuid, code: &str) -> Result<(), WorkerError> {
    sqlx::query("UPDATE ops.email_deliveries SET status='FAILED',last_error_code=$2 WHERE id=$1")
        .bind(id)
        .bind(code)
        .execute(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?;
    Ok(())
}
