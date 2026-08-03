async fn process_privacy_notification_claim(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    match process_privacy_notification(state, job, event).await {
        Ok(()) => Ok(()),
        Err(WorkerError::Job(error)) => Err(WorkerError::Job(error)),
        Err(error) => {
            let (code, detail, retryable) = match error {
                WorkerError::Database => (
                    "PRIVACY_NOTIFICATION_BINDING_UNAVAILABLE",
                    "privacy notice authority could not be loaded",
                    true,
                ),
                WorkerError::Delivery => (
                    "PRIVACY_NOTIFICATION_DELIVERY_FAILED",
                    "privacy notice provider outcome is unavailable",
                    true,
                ),
                WorkerError::Contract => (
                    "PRIVACY_NOTIFICATION_CONTRACT_INVALID",
                    "privacy notice authority binding is invalid",
                    false,
                ),
                WorkerError::Cryptography => (
                    "PRIVACY_NOTIFICATION_DECRYPTION_FAILED",
                    "privacy notice protected field could not be verified",
                    false,
                ),
                WorkerError::Initialization => (
                    "PRIVACY_NOTIFICATION_WORKER_INVALID",
                    "privacy notice worker state is invalid",
                    false,
                ),
                WorkerError::Job(error) => return Err(WorkerError::Job(error)),
            };
            state
                .worker
                .fail(
                    &state.pool,
                    job,
                    code,
                    detail,
                    retryable,
                    serde_json::json!({
                        "eventId": event.id,
                        "retentionRequestId": event.aggregate_id,
                    }),
                )
                .await
                .map(|_| ())
                .map_err(WorkerError::Job)
        }
    }
}

async fn process_privacy_notification(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let authority = load_privacy_notification_authority(&state.pool, event.id).await?;
    let validated = validate_privacy_notification(event, authority)?;
    let message = privacy_notification_message(state, &validated)?;
    let recipient_hash = sha256_hex(message.0.to.as_bytes());
    let row = sqlx::query(
        "INSERT INTO ops.email_deliveries( \
           message_type,recipient_hash,template_version,object_type,object_id,status,attempt_count \
         ) VALUES($1,$2,'privacy-v1','privacy_request',$3,'SENDING',1) \
         ON CONFLICT(message_type,object_id,recipient_hash) WHERE object_id IS NOT NULL \
         DO UPDATE SET status=CASE WHEN ops.email_deliveries.status='DELIVERED' \
             THEN 'DELIVERED' ELSE 'SENDING' END, \
           attempt_count=CASE WHEN ops.email_deliveries.status='DELIVERED' \
             THEN ops.email_deliveries.attempt_count \
             ELSE ops.email_deliveries.attempt_count+1 END, \
           last_error_code=NULL \
         RETURNING id,status",
    )
    .bind(&event.event_type)
    .bind(recipient_hash)
    .bind(validated.retention_request_id)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let delivery_id: Uuid = row.try_get("id").map_err(|_| WorkerError::Database)?;
    let status: String = row.try_get("status").map_err(|_| WorkerError::Database)?;
    match privacy_delivery_disposition(&status)? {
        PrivacyDeliveryDisposition::CompleteReplay => {
            complete_privacy_notification(state, job, event, &validated, delivery_id, None, true)
                .await?;
            return Ok(());
        }
        PrivacyDeliveryDisposition::Send => {}
    }
    let channel = privacy_delivery_channel(&validated.endpoint.channel)?;
    let provider_id = state
        .delivery
        .send_for_channel_with_key(&message.0, channel, &validated.event_envelope_digest)
        .await
        .map_err(|_| WorkerError::Delivery);
    let provider_id = match provider_id {
        Ok(provider_id) => provider_id,
        Err(error) => {
            mark_failed(state, delivery_id, "PRIVACY_NOTIFICATION_DELIVERY_FAILED").await?;
            return Err(error);
        }
    };
    complete_privacy_notification(
        state,
        job,
        event,
        &validated,
        delivery_id,
        Some(&provider_id),
        false,
    )
    .await
}

// This is the only notification-worker read across the privacy/communication
// ownership boundary. The SECURITY DEFINER function must return the exact
// closed JSON consumed by `validate_privacy_notification`; this worker never
// reads privacy request, transition receipt, outbox, or endpoint tables
// directly.
async fn load_privacy_notification_authority(
    pool: &PgPool,
    event_id: Uuid,
) -> Result<serde_json::Value, WorkerError> {
    sqlx::query_scalar::<_, serde_json::Value>(
        "SELECT ops.read_privacy_request_notification_delivery_v1($1)",
    )
    .bind(event_id)
    .fetch_optional(pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .ok_or(WorkerError::Contract)
}

async fn complete_privacy_notification(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
    validated: &ValidatedPrivacyNotification,
    delivery_id: Uuid,
    provider_id: Option<&str>,
    deduplicated: bool,
) -> Result<(), WorkerError> {
    let mut transaction = state
        .pool
        .begin()
        .await
        .map_err(|_| WorkerError::Database)?;
    if let Some(provider_id) = provider_id {
        let changed = sqlx::query(
            "UPDATE ops.email_deliveries \
                SET status='DELIVERED',provider_message_id=$2,delivered_at=clock_timestamp() \
              WHERE id=$1 AND status='SENDING'",
        )
        .bind(delivery_id)
        .bind(provider_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| WorkerError::Database)?
        .rows_affected();
        if changed != 1 {
            return Err(WorkerError::Database);
        }
    }
    let completed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
          WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
    )
    .bind(&event.consumer_id)
    .bind(event.id)
    .execute(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?
    .rows_affected();
    if completed != 1 {
        return Err(WorkerError::Database);
    }
    transaction
        .commit()
        .await
        .map_err(|_| WorkerError::Database)?;
    let mut result = serde_json::json!({
        "eventId": event.id,
        "retentionRequestId": validated.retention_request_id,
        "deliveryId": delivery_id,
        "deduplicated": deduplicated,
    });
    if let Some(transition_receipt_id) = validated.transition_receipt_id {
        result["transitionReceiptId"] = serde_json::json!(transition_receipt_id);
    }
    state
        .worker
        .complete(&state.pool, job, result)
        .await
        .map_err(WorkerError::Job)?;
    tracing::info!(
        event_id = %event.id,
        retention_request_id = %validated.retention_request_id,
        delivery_id = %delivery_id,
        deduplicated,
        "privacy request notification completed"
    );
    Ok(())
}

fn privacy_notification_message(
    state: &State,
    notification: &ValidatedPrivacyNotification,
) -> Result<SensitivePrivacyEmail, WorkerError> {
    let to = decrypt_privacy_endpoint(state, &notification.endpoint)?;
    let (subject, text_body, html_body) = render_privacy_notification(state, notification)?;
    Ok(SensitivePrivacyEmail(EmailMessage {
        from: state.from_email.clone(),
        to,
        subject,
        text_body,
        html_body,
    }))
}

struct SensitivePrivacyEmail(EmailMessage);

impl Drop for SensitivePrivacyEmail {
    fn drop(&mut self) {
        self.0.from.zeroize();
        self.0.to.zeroize();
        self.0.subject.zeroize();
        self.0.text_body.zeroize();
        self.0.html_body.zeroize();
    }
}

fn decrypt_privacy_endpoint(
    state: &State,
    endpoint: &PrivacyNotificationEndpointBinding,
) -> Result<String, WorkerError> {
    let logical_type = endpoint_logical_type(&endpoint.channel).ok_or(WorkerError::Contract)?;
    let endpoint_id = endpoint.endpoint_id.to_string();
    let parts = [
        "intake.communication_endpoints",
        "endpoint_ciphertext",
        endpoint_id.as_str(),
        logical_type,
        "1",
    ];
    let plaintext = decrypt_bound_text(
        &state.field_keys,
        &endpoint.endpoint_ciphertext_base64,
        &endpoint.encryption_key_id,
        &endpoint.endpoint_aad_digest,
        &parts,
        16_384,
        None,
    )?;
    validate_bounded_text(&plaintext, 16_384)?;
    Ok(plaintext)
}

fn decrypt_transition_text(
    state: &State,
    transition_receipt_id: Option<Uuid>,
    field: &'static str,
    sealed: SealedTextRef<'_>,
    maximum_chars: usize,
) -> Result<String, WorkerError> {
    let receipt_id = transition_receipt_id
        .ok_or(WorkerError::Contract)?
        .to_string();
    let field_kind = privacy_sealed_field_kind(field)?;
    let parts = [
        "ops.privacy_request_sealed_content_v2",
        "sealed_ciphertext",
        receipt_id.as_str(),
        field_kind,
        "1",
    ];
    decrypt_bound_text(
        &state.field_keys,
        sealed.ciphertext_base64,
        sealed.encryption_key_id,
        sealed.aad_digest,
        &parts,
        maximum_chars,
        Some(sealed.sha256),
    )
}

fn privacy_sealed_field_kind(field: &str) -> Result<&'static str, WorkerError> {
    match field {
        "reason" => Ok("REASON"),
        "extensionReason" => Ok("EXTENSION_REASON"),
        "rejectionReason" => Ok("REJECTION_REASON"),
        "appealInstructions" => Ok("APPEAL_INSTRUCTIONS"),
        _ => Err(WorkerError::Contract),
    }
}

fn decrypt_bound_text(
    field_keys: &EnvelopeKeyRing,
    ciphertext_base64: &str,
    encryption_key_id: &str,
    aad_digest: &str,
    aad_parts: &[&str],
    maximum_chars: usize,
    expected_plaintext_sha256: Option<&str>,
) -> Result<String, WorkerError> {
    let expected_aad_digest = sha256_hex(aad_parts.join("\0").as_bytes());
    if expected_aad_digest != aad_digest {
        return Err(WorkerError::Contract);
    }
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(ciphertext_base64)
        .map_err(|_| WorkerError::Contract)?;
    if base64::engine::general_purpose::STANDARD.encode(&ciphertext) != ciphertext_base64 {
        return Err(WorkerError::Contract);
    }
    let token = std::str::from_utf8(&ciphertext).map_err(|_| WorkerError::Cryptography)?;
    let mut segments = token.split('.');
    let _prefix = segments.next().ok_or(WorkerError::Cryptography)?;
    let token_key_id = segments.next().ok_or(WorkerError::Cryptography)?;
    let _nonce = segments.next().ok_or(WorkerError::Cryptography)?;
    let _ciphertext = segments.next().ok_or(WorkerError::Cryptography)?;
    if segments.next().is_some() || token_key_id != encryption_key_id {
        return Err(WorkerError::Contract);
    }
    let mut plaintext = decrypt("gurine-fe-v1", field_keys, aad_parts, token)
        .map_err(|_| WorkerError::Cryptography)?;
    if expected_plaintext_sha256.is_some_and(|digest| sha256_hex(&plaintext) != digest) {
        plaintext.zeroize();
        return Err(WorkerError::Contract);
    }
    let mut text = match String::from_utf8(plaintext) {
        Ok(text) => text,
        Err(error) => {
            let mut plaintext = error.into_bytes();
            plaintext.zeroize();
            return Err(WorkerError::Cryptography);
        }
    };
    if validate_bounded_text(&text, maximum_chars).is_err() {
        text.zeroize();
        return Err(WorkerError::Contract);
    }
    Ok(text)
}

fn privacy_delivery_channel(channel: &str) -> Result<&'static str, WorkerError> {
    match channel {
        "SMTP_EMAIL" => Ok("EMAIL"),
        "TELEGRAM_BOT_API" => Ok("TELEGRAM"),
        "META_WHATSAPP_BUSINESS_CLOUD" => Ok("WHATSAPP"),
        "LINE_MESSAGING_API" => Ok("LINE"),
        "SOLAPI_SMS" => Ok("SMS"),
        "SOLAPI_KAKAO_BIZMESSAGE" => Ok("KAKAO"),
        // No live VOICE or SIGNED_WEBHOOK adapter exists in the notification
        // gateway. Treating either as email would create a false receipt.
        "TWILIO_VOICE" | "SIGNED_WEBHOOK" => Err(WorkerError::Contract),
        _ => Err(WorkerError::Contract),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PrivacyDeliveryDisposition {
    CompleteReplay,
    Send,
}

fn privacy_delivery_disposition(
    persisted_status: &str,
) -> Result<PrivacyDeliveryDisposition, WorkerError> {
    match persisted_status {
        "DELIVERED" => Ok(PrivacyDeliveryDisposition::CompleteReplay),
        "SENDING" => Ok(PrivacyDeliveryDisposition::Send),
        _ => Err(WorkerError::Contract),
    }
}
