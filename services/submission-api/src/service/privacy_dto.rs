use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use gurine_application::privacy::{
    EncryptedPrivacyContact, EndpointProofKind, EndpointProofProvider, PrivacyContactChannel,
    PrivacyIdentityProofClaim,
};
use gurine_auth::assertion::canonical::{key_id, sha256_hex};
use gurine_domain::privacy::{PrivacyDigest, PrivacyRequestScope, PrivacyRequestType};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Sha256;
use uuid::Uuid;
use zeroize::Zeroize;

use super::{RequestContext, ServiceError, common};

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct CreatePrivacyRequestBody {
    pub request_type: PrivacyRequestType,
    pub subject_identity_proof: IdentityProof,
    pub jurisdiction: String,
    pub scope: PrivacyRequestScope,
    pub contact_endpoint: EndpointEnrollment,
    pub statement: String,
    pub attestation: bool,
    pub privacy_consent: bool,
    pub abuse_proof: AbuseProof,
}

impl CreatePrivacyRequestBody {
    pub fn parse(bytes: &[u8]) -> Result<Self, ServiceError> {
        let mut body: Self =
            serde_json::from_slice(bytes).map_err(|_| ServiceError::InvalidParameter)?;
        if !body.attestation
            || !body.privacy_consent
            || body.statement.chars().count() > 10_000
            || body.statement.trim().is_empty()
            || body.statement.contains('\0')
        {
            body.zeroize_sensitive();
            return Err(ServiceError::InvalidParameter);
        }
        if matches!(&body.contact_endpoint, EndpointEnrollment::Voice { .. }) {
            body.zeroize_sensitive();
            return Err(ServiceError::PrivacyVoiceConsentAuthorityMissing);
        }
        if let Err(error) = body.abuse_proof.validate("createPrivacyRequest") {
            body.zeroize_sensitive();
            return Err(error);
        }
        Ok(body)
    }

    pub fn abuse_proof_value(&self) -> Result<Value, ServiceError> {
        serde_json::to_value(&self.abuse_proof).map_err(|_| ServiceError::InvalidParameter)
    }

    pub(super) fn zeroize_sensitive(&mut self) {
        self.statement.zeroize();
        self.subject_identity_proof.zeroize_sensitive();
        self.contact_endpoint.zeroize_sensitive();
        self.abuse_proof.token.zeroize();
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ExchangePrivacyReceiptBody {
    pub token: String,
}

impl ExchangePrivacyReceiptBody {
    pub fn parse(bytes: &[u8]) -> Result<Self, ServiceError> {
        let mut body: Self =
            serde_json::from_slice(bytes).map_err(|_| ServiceError::PrivacyTokenInvalid)?;
        if !(32..=4096).contains(&body.token.len()) || body.token.contains('\0') {
            body.token.zeroize();
            return Err(ServiceError::PrivacyTokenInvalid);
        }
        Ok(body)
    }
}

#[derive(Deserialize)]
#[serde(
    deny_unknown_fields,
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub(super) enum IdentityProof {
    #[serde(rename = "RESPONSE_RECEIPT")]
    ResponseReceipt {
        receipt_id: Uuid,
        possession_token: String,
    },
    #[serde(rename = "VERIFIED_ENDPOINT")]
    VerifiedEndpoint {
        endpoint_challenge_id: Uuid,
        endpoint_proof: EndpointVerificationProof,
    },
}

impl IdentityProof {
    fn zeroize_sensitive(&mut self) {
        match self {
            Self::ResponseReceipt {
                possession_token, ..
            } => possession_token.zeroize(),
            Self::VerifiedEndpoint { endpoint_proof, .. } => {
                endpoint_proof.zeroize_sensitive();
            }
        }
    }

    pub fn derive_claim(
        &mut self,
        token_hmac_key: &[u8],
    ) -> Result<PrivacyIdentityProofClaim, ServiceError> {
        match self {
            Self::ResponseReceipt {
                receipt_id,
                possession_token,
            } => {
                let possession_token_hmac = validate_secret(possession_token, 32, 4096)
                    .and_then(|()| hmac_digest(token_hmac_key, possession_token));
                possession_token.zeroize();
                Ok(PrivacyIdentityProofClaim::ResponseReceipt {
                    receipt_id: *receipt_id,
                    possession_token_hmac: possession_token_hmac?,
                })
            }
            Self::VerifiedEndpoint {
                endpoint_challenge_id,
                endpoint_proof,
            } => endpoint_proof.derive_claim(*endpoint_challenge_id, token_hmac_key),
        }
    }
}

#[derive(Deserialize)]
#[serde(
    deny_unknown_fields,
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub(super) enum EndpointVerificationProof {
    #[serde(rename = "EMAIL_LINK")]
    EmailLink { token: String },
    #[serde(rename = "SMS_OTP")]
    SmsOtp { code: String },
    #[serde(rename = "PROVIDER_SIGNED_BINDING")]
    ProviderSignedBinding {
        provider: Provider,
        binding_token: String,
    },
}

impl EndpointVerificationProof {
    fn zeroize_sensitive(&mut self) {
        match self {
            Self::EmailLink { token } => token.zeroize(),
            Self::SmsOtp { code } => code.zeroize(),
            Self::ProviderSignedBinding { binding_token, .. } => binding_token.zeroize(),
        }
    }

    fn derive_claim(
        &mut self,
        endpoint_challenge_id: Uuid,
        token_hmac_key: &[u8],
    ) -> Result<PrivacyIdentityProofClaim, ServiceError> {
        let (proof_kind, secret, provider, minimum, maximum) = match self {
            Self::EmailLink { token } => (EndpointProofKind::EmailLink, token, None, 32, 4096),
            Self::SmsOtp { code } => (EndpointProofKind::SmsOtp, code, None, 4, 12),
            Self::ProviderSignedBinding {
                provider,
                binding_token,
            } => (
                EndpointProofKind::ProviderSignedBinding,
                binding_token,
                Some((*provider).into()),
                32,
                4096,
            ),
        };
        let proof_verifier_hmac = validate_secret(secret, minimum, maximum)
            .and_then(|()| hmac_digest(token_hmac_key, secret));
        secret.zeroize();
        Ok(PrivacyIdentityProofClaim::VerifiedEndpoint {
            endpoint_challenge_id,
            proof_kind,
            proof_verifier_hmac: proof_verifier_hmac?,
            provider,
        })
    }
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(super) enum Provider {
    TelegramBotApi,
    MetaWhatsappBusinessCloud,
    LineMessagingApi,
    SolapiKakaoBizmessage,
    TwilioVoice,
}

impl From<Provider> for EndpointProofProvider {
    fn from(value: Provider) -> Self {
        match value {
            Provider::TelegramBotApi => Self::TelegramBotApi,
            Provider::MetaWhatsappBusinessCloud => Self::MetaWhatsappBusinessCloud,
            Provider::LineMessagingApi => Self::LineMessagingApi,
            Provider::SolapiKakaoBizmessage => Self::SolapiKakaoBizmessage,
            Provider::TwilioVoice => Self::TwilioVoice,
        }
    }
}

#[derive(Deserialize)]
#[serde(
    deny_unknown_fields,
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "channel"
)]
pub(super) enum EndpointEnrollment {
    #[serde(rename = "EMAIL")]
    Email { address: String, locale: String },
    #[serde(rename = "SMS")]
    Sms { e164: String, locale: String },
    #[serde(rename = "TELEGRAM")]
    Telegram {
        provider_subject_token: String,
        locale: String,
    },
    #[serde(rename = "WHATSAPP")]
    Whatsapp {
        provider_subject_token: String,
        locale: String,
    },
    #[serde(rename = "LINE")]
    Line {
        provider_subject_token: String,
        locale: String,
    },
    #[serde(rename = "KAKAO")]
    Kakao { e164: String, locale: String },
    #[serde(rename = "VOICE")]
    Voice {
        e164: String,
        locale: String,
        explicit_voice_consent_receipt_id: Uuid,
    },
}

struct EndpointMaterial {
    channel: PrivacyContactChannel,
    raw: String,
    locale: String,
    explicit_voice_consent_receipt_id: Option<Uuid>,
}

impl Drop for EndpointMaterial {
    fn drop(&mut self) {
        self.raw.zeroize();
    }
}

impl EndpointEnrollment {
    fn zeroize_sensitive(&mut self) {
        match self {
            Self::Email { address, .. } => address.zeroize(),
            Self::Sms { e164, .. } | Self::Kakao { e164, .. } | Self::Voice { e164, .. } => {
                e164.zeroize();
            }
            Self::Telegram {
                provider_subject_token,
                ..
            }
            | Self::Whatsapp {
                provider_subject_token,
                ..
            }
            | Self::Line {
                provider_subject_token,
                ..
            } => provider_subject_token.zeroize(),
        }
    }

    pub fn encrypt(
        &mut self,
        context: &RequestContext<'_>,
        endpoint_id: Uuid,
    ) -> Result<EncryptedPrivacyContact, ServiceError> {
        let mut material = self.take_material()?;
        let encrypted = common::encrypt_field_material(
            context,
            "intake.communication_endpoints",
            "endpoint_ciphertext",
            endpoint_id,
            material.channel.encryption_logical_type(),
            material.raw.as_bytes(),
        )?;
        Ok(EncryptedPrivacyContact {
            endpoint_id,
            channel: material.channel,
            endpoint_hmac: hmac_digest(&context.state.token_hmac_key, &material.raw)?,
            hmac_key_version: key_id(&context.state.token_hmac_key),
            endpoint_ciphertext: encrypted.ciphertext,
            encryption_key_id: encrypted.encryption_key_id,
            endpoint_aad_digest: PrivacyDigest::try_new(encrypted.aad_digest)
                .map_err(|_| ServiceError::Cryptography)?,
            locale: std::mem::take(&mut material.locale),
            explicit_voice_consent_receipt_id: material.explicit_voice_consent_receipt_id,
        })
    }

    fn take_material(&mut self) -> Result<EndpointMaterial, ServiceError> {
        let (channel, raw, locale) = match self {
            Self::Email { address, locale } => {
                let normalized =
                    common::normalized_email(address).map_err(|_| ServiceError::InvalidParameter);
                address.zeroize();
                (
                    PrivacyContactChannel::Email,
                    normalized?,
                    std::mem::take(locale),
                )
            }
            Self::Sms { e164, locale } => {
                let e164 = std::mem::take(e164);
                (
                    PrivacyContactChannel::Sms,
                    validate_e164(e164)?,
                    std::mem::take(locale),
                )
            }
            Self::Telegram {
                provider_subject_token,
                locale,
            } => (
                PrivacyContactChannel::Telegram,
                validate_provider_token(std::mem::take(provider_subject_token))?,
                std::mem::take(locale),
            ),
            Self::Whatsapp {
                provider_subject_token,
                locale,
            } => (
                PrivacyContactChannel::Whatsapp,
                validate_provider_token(std::mem::take(provider_subject_token))?,
                std::mem::take(locale),
            ),
            Self::Line {
                provider_subject_token,
                locale,
            } => (
                PrivacyContactChannel::Line,
                validate_provider_token(std::mem::take(provider_subject_token))?,
                std::mem::take(locale),
            ),
            Self::Kakao { e164, locale } => {
                let e164 = std::mem::take(e164);
                (
                    PrivacyContactChannel::Kakao,
                    validate_e164(e164)?,
                    std::mem::take(locale),
                )
            }
            Self::Voice {
                e164,
                locale,
                explicit_voice_consent_receipt_id,
            } => {
                let _ = (&*locale, *explicit_voice_consent_receipt_id);
                e164.zeroize();
                return Err(ServiceError::PrivacyVoiceConsentAuthorityMissing);
            }
        };
        validate_bounded_text(&locale, 2, 35)?;
        Ok(EndpointMaterial {
            channel,
            raw,
            locale,
            explicit_voice_consent_receipt_id: None,
        })
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct AbuseProof {
    provider: AbuseProvider,
    token: String,
    action: String,
    issued_at_epoch_seconds: Option<i64>,
}

impl AbuseProof {
    fn validate(&self, expected_action: &str) -> Result<(), ServiceError> {
        if self.action != expected_action
            || !(1..=4096).contains(&self.token.len())
            || self.token.contains('\0')
            || self.issued_at_epoch_seconds.is_some_and(|value| value < 0)
            || matches!(self.provider, AbuseProvider::SyntheticTest)
                && self.issued_at_epoch_seconds.is_none()
        {
            return Err(ServiceError::AbuseProofInvalid);
        }
        Ok(())
    }
}

impl Drop for AbuseProof {
    fn drop(&mut self) {
        self.token.zeroize();
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum AbuseProvider {
    Turnstile,
    Hcaptcha,
    SyntheticTest,
}

fn hmac_digest(key: &[u8], secret: &str) -> Result<PrivacyDigest, ServiceError> {
    PrivacyDigest::try_new(common::token_hmac(key, secret)?).map_err(|_| ServiceError::Cryptography)
}

fn validate_secret(value: &str, min: usize, max: usize) -> Result<(), ServiceError> {
    if !(min..=max).contains(&value.len()) || value.contains('\0') {
        Err(ServiceError::IdentityProofInvalid)
    } else {
        Ok(())
    }
}

fn validate_bounded_text(value: &str, min: usize, max: usize) -> Result<(), ServiceError> {
    if !(min..=max).contains(&value.chars().count())
        || value.trim() != value
        || value.contains('\0')
    {
        Err(ServiceError::InvalidParameter)
    } else {
        Ok(())
    }
}

fn validate_provider_token(mut value: String) -> Result<String, ServiceError> {
    if validate_secret(&value, 16, 4096).is_err() {
        value.zeroize();
        Err(ServiceError::InvalidParameter)
    } else {
        Ok(value)
    }
}

fn validate_e164(mut value: String) -> Result<String, ServiceError> {
    let valid = (8..=16).contains(&value.len())
        && value.starts_with('+')
        && value.as_bytes()[1..].iter().all(u8::is_ascii_digit);
    if valid {
        Ok(value)
    } else {
        value.zeroize();
        Err(ServiceError::InvalidParameter)
    }
}

/// Re-derives the privacy receipt secret for an exact idempotent create.
/// The NUL-separated preimage follows the existing proof-domain convention;
/// only the derived token leaves this boundary and neither preimage nor token
/// is debuggable or persisted.
pub(super) fn derived_privacy_receipt_token(
    key: &[u8],
    operation: &str,
    idempotency_key_hash: &str,
    request_hash: &str,
) -> Result<String, ServiceError> {
    if operation != "createPrivacyRequest"
        || !is_lower_sha256(idempotency_key_hash)
        || !is_lower_sha256(request_hash)
    {
        return Err(ServiceError::Cryptography);
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| ServiceError::Cryptography)?;
    mac.update(b"privacy-receipt-v2\0");
    mac.update(operation.as_bytes());
    mac.update(b"\0");
    mac.update(idempotency_key_hash.as_bytes());
    mac.update(b"\0");
    mac.update(request_hash.as_bytes());
    Ok(URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

pub(super) struct PrivacyReceiptMaterial {
    token: String,
    token_hmac: PrivacyDigest,
    token_sha256: PrivacyDigest,
    key_version: String,
}

impl PrivacyReceiptMaterial {
    pub fn derive(
        key: &[u8],
        idempotency_key_hash: &str,
        request_hash: &str,
    ) -> Result<Self, ServiceError> {
        let token = derived_privacy_receipt_token(
            key,
            "createPrivacyRequest",
            idempotency_key_hash,
            request_hash,
        )?;
        let token_hmac = PrivacyDigest::try_new(common::token_hmac(key, &token)?)
            .map_err(|_| ServiceError::Cryptography)?;
        let token_sha256 = PrivacyDigest::try_new(sha256_hex(token.as_bytes()))
            .map_err(|_| ServiceError::Cryptography)?;
        Ok(Self {
            token,
            token_hmac,
            token_sha256,
            key_version: key_id(key),
        })
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    pub const fn token_hmac(&self) -> &PrivacyDigest {
        &self.token_hmac
    }

    pub const fn token_sha256(&self) -> &PrivacyDigest {
        &self.token_sha256
    }

    pub fn key_version(&self) -> &str {
        &self.key_version
    }
}

impl Drop for PrivacyReceiptMaterial {
    fn drop(&mut self) {
        self.token.zeroize();
    }
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
#[path = "privacy_dto_tests.rs"]
mod tests;
