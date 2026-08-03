use super::*;

pub(super) async fn arm_createresponserequest(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let email = normalized_email(
        string_value(payload, "recipientEmail").ok_or(ServiceError::InvalidRequest)?,
    )?;
    let encrypted = encrypt_control_field(
        field_keys,
        "editorial.response_requests",
        "recipient_email_encrypted",
        id,
        "email-address",
        email.as_bytes(),
    )?;
    sqlx::query(
        "INSERT INTO editorial.response_requests(id,case_id,party_type,party_name, \
         recipient_email_hash,recipient_email_encrypted,questions, \
         requested_publication_scope,due_at,status,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'DRAFT',$10)",
    )
    .bind(id)
    .bind(case_id)
    .bind(string_value(payload, "partyType").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "partyName").ok_or(ServiceError::InvalidRequest)?)
    .bind(sha256(email.as_bytes()))
    .bind(encrypted)
    .bind(
        payload
            .get("questions")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(
        payload
            .get("requestedPublicationScope")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(timestamp_value(payload, "dueAt")?.ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_saveresponserequestdraft(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let request =
        uuid_value(payload, &["responseRequestId"]).ok_or(ServiceError::InvalidRequest)?;
    let (email_hash, encrypted) =
        if let Some(raw) = payload.get("recipientEmail").and_then(Value::as_str) {
            let email = normalized_email(raw)?;
            (
                Some(sha256(email.as_bytes())),
                Some(encrypt_control_field(
                    field_keys,
                    "editorial.response_requests",
                    "recipient_email_encrypted",
                    request,
                    "email-address",
                    email.as_bytes(),
                )?),
            )
        } else {
            (None, None)
        };
    let changed = sqlx::query(
        "UPDATE editorial.response_requests SET recipient_email_hash=COALESCE($2,recipient_email_hash), \
         recipient_email_encrypted=COALESCE($3,recipient_email_encrypted), \
         questions=COALESCE($4,questions),due_at=COALESCE($5,due_at), \
         requested_publication_scope=COALESCE($6,requested_publication_scope) \
         WHERE id=$1 AND status='DRAFT'",
    )
    .bind(request)
    .bind(email_hash)
    .bind(encrypted)
    .bind(payload.get("questions").cloned())
    .bind(timestamp_value(payload, "dueAt")?)
    .bind(payload.get("requestedPublicationScope").cloned())
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}
