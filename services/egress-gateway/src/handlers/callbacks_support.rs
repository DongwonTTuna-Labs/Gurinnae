use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce, aead::Aead};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub(super) fn canonical_json(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let sorted: BTreeMap<_, _> = object
                .iter()
                .map(|(key, value)| (key.clone(), canonical_json(value)))
                .collect();
            Value::Object(sorted.into_iter().collect())
        }
        Value::Array(values) => Value::Array(values.iter().map(canonical_json).collect()),
        _ => value.clone(),
    }
}

pub(super) fn smtp_item(body: &[u8]) -> Value {
    let digest = sha256_hex(body);
    json!({"ordinal":0,"effectKind":"DELIVERY_OBSERVATION","assertedState":"DELIVERED","processingDisposition":"APPLIED","providerEventIdentityHmac":digest,"itemDigest":digest,"normalizedEvidenceDigest":digest})
}

pub(super) fn callback_channel(path: &str, smtp: bool) -> Option<&'static str> {
    if smtp {
        return Some("SMTP_EMAIL");
    }
    match path.to_ascii_lowercase().as_str() {
        "telegram" => Some("TELEGRAM_BOT_API"),
        "whatsapp" => Some("META_WHATSAPP_BUSINESS_CLOUD"),
        "line" => Some("LINE_MESSAGING_API"),
        "sms" => Some("SOLAPI_SMS"),
        "kakao" => Some("SOLAPI_KAKAO_BIZMESSAGE"),
        _ => None,
    }
}

pub(super) fn env_name(channel: &str) -> &'static str {
    match channel {
        "TELEGRAM_BOT_API" => "TELEGRAM",
        "META_WHATSAPP_BUSINESS_CLOUD" => "WHATSAPP",
        "LINE_MESSAGING_API" => "LINE",
        "SOLAPI_SMS" => "SMS",
        "SOLAPI_KAKAO_BIZMESSAGE" => "KAKAO",
        _ => "UNKNOWN",
    }
}

pub(super) fn callback_env_name(channel: &str) -> &'static str {
    match channel {
        "SMTP_EMAIL" => "SMTP",
        _ => env_name(channel),
    }
}

pub(super) fn auth_method(channel: &str) -> &'static str {
    match channel {
        "TELEGRAM_BOT_API" => "TELEGRAM_SECRET_TOKEN",
        "META_WHATSAPP_BUSINESS_CLOUD" => "META_HMAC_SHA256",
        "LINE_MESSAGING_API" => "LINE_HMAC_SHA256",
        _ => "SOLAPI_SIGNATURE",
    }
}

pub(super) fn operation_id(channel: &str) -> &'static str {
    match channel {
        "SMTP_EMAIL" => "acceptSmtpDsn",
        "TELEGRAM_BOT_API" => "receiveTelegramWebhook",
        "META_WHATSAPP_BUSINESS_CLOUD" => "receiveWhatsAppWebhook",
        "LINE_MESSAGING_API" => "receiveLineWebhook",
        "SOLAPI_SMS" => "receiveSolapiSmsCallback",
        _ => "receiveSolapiKakaoCallback",
    }
}

pub(super) fn is_digest(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

pub(super) fn sha256_hex(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub(super) fn hex_bytes(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(super) fn key_id() -> String {
    std::env::var("COMMUNICATION_CALLBACK_ENCRYPTION_KEY_ID")
        .unwrap_or_else(|_| "communication-callback-key-v1".into())
}

pub(super) fn callback_key() -> Option<[u8; 32]> {
    BASE64
        .decode(std::env::var("COMMUNICATION_CALLBACK_ENCRYPTION_KEY").ok()?)
        .ok()?
        .try_into()
        .ok()
}

pub(super) fn encrypt(key: &[u8; 32], body: &[u8]) -> Option<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new_from_slice(key).ok()?;
    let mut nonce_bytes = [0_u8; 12];
    getrandom::fill(&mut nonce_bytes).ok()?;
    let nonce = Nonce::try_from(nonce_bytes.as_slice()).ok()?;
    let mut out = nonce_bytes.to_vec();
    out.extend(cipher.encrypt(&nonce, body).ok()?);
    Some(out)
}

pub(super) fn verify_signature(secret: &str, body: &[u8], supplied: &str) -> bool {
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret.as_bytes()) else {
        return false;
    };
    mac.update(body);
    let expected = hex_bytes(&mac.finalize().into_bytes());
    supplied
        .strip_prefix("sha256=")
        .unwrap_or(supplied)
        .eq_ignore_ascii_case(&expected)
}
