trait SealedFieldsRef {
    fn as_ref(&self) -> SealedTextRef<'_>;
}

struct SealedTextRef<'a> {
    ciphertext_base64: &'a str,
    sha256: &'a str,
    encryption_key_id: &'a str,
    aad_digest: &'a str,
}

macro_rules! impl_sealed_ref {
    ($type:ty) => {
        impl SealedFieldsRef for $type {
            fn as_ref(&self) -> SealedTextRef<'_> {
                SealedTextRef {
                    ciphertext_base64: &self.ciphertext_base64,
                    sha256: &self.sha256,
                    encryption_key_id: &self.encryption_key_id,
                    aad_digest: &self.aad_digest,
                }
            }
        }
    };
}

impl_sealed_ref!(ReasonSealedFields);
impl_sealed_ref!(ExtensionReasonSealedFields);
impl_sealed_ref!(RejectionReasonSealedFields);
impl_sealed_ref!(AppealInstructionsSealedFields);

fn validate_sealed_fields(
    sealed: SealedTextRef<'_>,
    field: &str,
    maximum_chars: usize,
) -> Result<(), WorkerError> {
    validate_sha256(sealed.sha256)?;
    validate_sha256(sealed.aad_digest)?;
    validate_bounded_text(sealed.encryption_key_id, 200)?;
    if sealed.ciphertext_base64.is_empty()
        || sealed.ciphertext_base64.len() > maximum_chars.saturating_mul(8).max(1024)
        || field.is_empty()
    {
        return Err(WorkerError::Contract);
    }
    Ok(())
}

fn validate_endpoint_ciphertext(
    endpoint: &PrivacyNotificationEndpointBinding,
) -> Result<(), WorkerError> {
    if endpoint.endpoint_ciphertext_base64.is_empty()
        || endpoint.endpoint_ciphertext_base64.len() > 32_768
        || endpoint_logical_type(&endpoint.channel).is_none()
    {
        return Err(WorkerError::Contract);
    }
    Ok(())
}

fn endpoint_logical_type(channel: &str) -> Option<&'static str> {
    match channel {
        "SMTP_EMAIL" => Some("email-address"),
        "SOLAPI_SMS"
        | "SOLAPI_KAKAO_BIZMESSAGE"
        | "TWILIO_VOICE"
        | "META_WHATSAPP_BUSINESS_CLOUD" => Some("phone-number"),
        "SIGNED_WEBHOOK" => Some("uri"),
        "TELEGRAM_BOT_API" | "LINE_MESSAGING_API" => Some("provider-identifier"),
        _ => None,
    }
}

fn validate_sha256(value: &str) -> Result<(), WorkerError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        Ok(())
    } else {
        Err(WorkerError::Contract)
    }
}

fn validate_bounded_text(value: &str, maximum_chars: usize) -> Result<(), WorkerError> {
    let chars = value.chars().count();
    if value.trim() == value && !value.contains('\0') && (1..=maximum_chars).contains(&chars) {
        Ok(())
    } else {
        Err(WorkerError::Contract)
    }
}

fn parse_timestamp(value: &str) -> Result<OffsetDateTime, WorkerError> {
    OffsetDateTime::parse(value, &Rfc3339).map_err(|_| WorkerError::Contract)
}

fn format_korean_timestamp(value: &str) -> Result<String, WorkerError> {
    let timestamp = parse_timestamp(value)?;
    let offset = UtcOffset::from_hms(9, 0, 0).map_err(|_| WorkerError::Contract)?;
    let local = timestamp.to_offset(offset);
    Ok(format!(
        "{:04}.{:02}.{:02} {:02}:{:02}",
        local.year(),
        u8::from(local.month()),
        local.day(),
        local.hour(),
        local.minute()
    ))
}

fn privacy_request_type_label(request_type: PrivacyRequestType) -> &'static str {
    match request_type {
        PrivacyRequestType::Access => "열람",
        PrivacyRequestType::Correction => "정정",
        PrivacyRequestType::Deletion => "삭제",
        PrivacyRequestType::Restriction => "처리정지",
    }
}
