use std::{future::Future, pin::Pin};

use gurine_auth::assertion::canonical::{canonical_json, sha256_hex};
use gurine_domain::privacy::{
    PrivacyDigest, PrivacyError, PrivacyIdentityState, PrivacyRequestScope, PrivacyRequestState,
    PrivacyRequestSummary, PrivacyRequestType,
};
use time::OffsetDateTime;
use uuid::Uuid;

pub use crate::privacy_extension::PrivacyExtensionInput;
pub use crate::privacy_status::{PrivacyNextActionCode, PrivacyRequestPublicStatus};

pub type PrivacyFuture<'a, T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send + 'a>>;

pub const PRIVACY_REQUEST_RECEIPT_COOKIE_NAME: &str = "gurine_privacy_request_receipt_session";

// The closed 1,000-item COMMUNICATION_ENDPOINT scope serializes to 90,120
// canonical bytes. ChaCha20-Poly1305 plus the gurine-fe-v1 envelope serializes
// to 120,229 bytes; 131,072 leaves a measured 10,843-byte safety margin.
const MAX_ENCRYPTED_PRIVACY_SCOPE_BYTES: usize = 131_072;
const MAX_ENCRYPTED_PRIVACY_STATEMENT_BYTES: usize = 65_536;

#[derive(Clone, Eq, PartialEq)]
pub enum PrivacyIdentityProofClaim {
    ResponseReceipt {
        receipt_id: Uuid,
        possession_token_hmac: PrivacyDigest,
    },
    VerifiedEndpoint {
        endpoint_challenge_id: Uuid,
        proof_kind: EndpointProofKind,
        proof_verifier_hmac: PrivacyDigest,
        provider: Option<EndpointProofProvider>,
    },
}

impl PrivacyIdentityProofClaim {
    pub fn validate(&self) -> Result<(), PrivacyCommandError> {
        let valid = match self {
            Self::ResponseReceipt { receipt_id, .. } => !receipt_id.is_nil(),
            Self::VerifiedEndpoint {
                endpoint_challenge_id,
                proof_kind,
                provider,
                ..
            } => {
                !endpoint_challenge_id.is_nil()
                    && matches!(
                        (proof_kind, provider),
                        (
                            EndpointProofKind::EmailLink | EndpointProofKind::SmsOtp,
                            None
                        ) | (EndpointProofKind::ProviderSignedBinding, Some(_))
                    )
            }
        };
        if valid {
            Ok(())
        } else {
            Err(PrivacyCommandError::IdentityProofInvalid)
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EndpointProofKind {
    EmailLink,
    SmsOtp,
    ProviderSignedBinding,
}

impl EndpointProofKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::EmailLink => "EMAIL_LINK",
            Self::SmsOtp => "SMS_OTP",
            Self::ProviderSignedBinding => "PROVIDER_SIGNED_BINDING",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EndpointProofProvider {
    TelegramBotApi,
    MetaWhatsappBusinessCloud,
    LineMessagingApi,
    SolapiKakaoBizmessage,
    TwilioVoice,
}

impl EndpointProofProvider {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TelegramBotApi => "TELEGRAM_BOT_API",
            Self::MetaWhatsappBusinessCloud => "META_WHATSAPP_BUSINESS_CLOUD",
            Self::LineMessagingApi => "LINE_MESSAGING_API",
            Self::SolapiKakaoBizmessage => "SOLAPI_KAKAO_BIZMESSAGE",
            Self::TwilioVoice => "TWILIO_VOICE",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrivacyContactChannel {
    Email,
    Sms,
    Telegram,
    Whatsapp,
    Line,
    Kakao,
    Voice,
}

impl PrivacyContactChannel {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Email => "EMAIL",
            Self::Sms => "SMS",
            Self::Telegram => "TELEGRAM",
            Self::Whatsapp => "WHATSAPP",
            Self::Line => "LINE",
            Self::Kakao => "KAKAO",
            Self::Voice => "VOICE",
        }
    }

    pub const fn persistence_channel(self) -> &'static str {
        match self {
            Self::Email => "SMTP_EMAIL",
            Self::Sms => "SOLAPI_SMS",
            Self::Telegram => "TELEGRAM_BOT_API",
            Self::Whatsapp => "META_WHATSAPP_BUSINESS_CLOUD",
            Self::Line => "LINE_MESSAGING_API",
            Self::Kakao => "SOLAPI_KAKAO_BIZMESSAGE",
            Self::Voice => "TWILIO_VOICE",
        }
    }

    pub const fn encryption_logical_type(self) -> &'static str {
        match self {
            Self::Email => "email-address",
            Self::Sms | Self::Whatsapp | Self::Kakao | Self::Voice => "phone-number",
            Self::Telegram | Self::Line => "provider-identifier",
        }
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct EncryptedPrivacyContact {
    pub endpoint_id: Uuid,
    pub channel: PrivacyContactChannel,
    pub endpoint_hmac: PrivacyDigest,
    pub hmac_key_version: String,
    pub endpoint_ciphertext: Vec<u8>,
    pub encryption_key_id: String,
    pub endpoint_aad_digest: PrivacyDigest,
    pub locale: String,
    pub explicit_voice_consent_receipt_id: Option<Uuid>,
}

impl EncryptedPrivacyContact {
    pub fn validate(&self) -> Result<(), PrivacyCommandError> {
        let voice_shape = matches!(self.channel, PrivacyContactChannel::Voice)
            == self.explicit_voice_consent_receipt_id.is_some();
        if self.endpoint_id.is_nil()
            || self.endpoint_ciphertext.is_empty()
            || self.endpoint_ciphertext.len() > 16_384
            || !(1..=100).contains(&self.hmac_key_version.chars().count())
            || !(1..=200).contains(&self.encryption_key_id.chars().count())
            || self.hmac_key_version.trim() != self.hmac_key_version
            || self.encryption_key_id.trim() != self.encryption_key_id
            || !(2..=35).contains(&self.locale.chars().count())
            || self.locale.trim() != self.locale
            || !voice_shape
            || self
                .explicit_voice_consent_receipt_id
                .is_some_and(|id| id.is_nil())
        {
            return Err(PrivacyCommandError::InvalidCommand);
        }
        Ok(())
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct EncryptedPrivacyScope {
    ciphertext: Vec<u8>,
    digest: PrivacyDigest,
    aad_digest: PrivacyDigest,
    encryption_key_id: String,
}

impl EncryptedPrivacyScope {
    pub fn try_new(
        ciphertext: Vec<u8>,
        digest: PrivacyDigest,
        aad_digest: PrivacyDigest,
        encryption_key_id: impl Into<String>,
    ) -> Result<Self, PrivacyCommandError> {
        let encryption_key_id = encryption_key_id.into();
        if ciphertext.is_empty()
            || ciphertext.len() > MAX_ENCRYPTED_PRIVACY_SCOPE_BYTES
            || !(1..=200).contains(&encryption_key_id.chars().count())
            || encryption_key_id.trim() != encryption_key_id
        {
            return Err(PrivacyCommandError::InvalidCommand);
        }
        Ok(Self {
            ciphertext,
            digest,
            aad_digest,
            encryption_key_id,
        })
    }

    pub fn ciphertext(&self) -> &[u8] {
        &self.ciphertext
    }

    pub const fn digest(&self) -> &PrivacyDigest {
        &self.digest
    }

    pub const fn aad_digest(&self) -> &PrivacyDigest {
        &self.aad_digest
    }

    pub fn encryption_key_id(&self) -> &str {
        &self.encryption_key_id
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct EncryptedPrivacyStatement {
    ciphertext: Vec<u8>,
    digest: PrivacyDigest,
    aad_digest: PrivacyDigest,
    encryption_key_id: String,
}

impl EncryptedPrivacyStatement {
    pub fn try_new(
        ciphertext: Vec<u8>,
        digest: PrivacyDigest,
        aad_digest: PrivacyDigest,
        encryption_key_id: impl Into<String>,
    ) -> Result<Self, PrivacyCommandError> {
        let encryption_key_id = encryption_key_id.into();
        if ciphertext.is_empty()
            || ciphertext.len() > MAX_ENCRYPTED_PRIVACY_STATEMENT_BYTES
            || !(1..=200).contains(&encryption_key_id.chars().count())
            || encryption_key_id.trim() != encryption_key_id
        {
            return Err(PrivacyCommandError::InvalidCommand);
        }
        Ok(Self {
            ciphertext,
            digest,
            aad_digest,
            encryption_key_id,
        })
    }

    pub fn ciphertext(&self) -> &[u8] {
        &self.ciphertext
    }

    pub const fn digest(&self) -> &PrivacyDigest {
        &self.digest
    }

    pub const fn aad_digest(&self) -> &PrivacyDigest {
        &self.aad_digest
    }

    pub fn encryption_key_id(&self) -> &str {
        &self.encryption_key_id
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct CreatePrivacyRequest {
    pub privacy_request_id: Uuid,
    pub communication_subject_id: Uuid,
    pub communication_subject_hmac_key_version: String,
    pub request_type: PrivacyRequestType,
    pub identity_proof: PrivacyIdentityProofClaim,
    pub jurisdiction: String,
    pub scope: PrivacyRequestScope,
    pub encrypted_scope: EncryptedPrivacyScope,
    pub contact: EncryptedPrivacyContact,
    pub encrypted_statement: EncryptedPrivacyStatement,
    pub receipt_token_hmac: PrivacyDigest,
    pub receipt_token_sha256: PrivacyDigest,
    pub receipt_token_key_version: String,
    pub idempotency_key_sha256: PrivacyDigest,
    pub request_sha256: PrivacyDigest,
    pub bff_issuer: String,
    pub transport_request_id: Uuid,
}

impl CreatePrivacyRequest {
    pub fn validate(mut self) -> Result<Self, PrivacyCommandError> {
        if self.privacy_request_id.is_nil()
            || self.communication_subject_id.is_nil()
            || self.communication_subject_id == self.privacy_request_id
            || self.transport_request_id.is_nil()
            || self.contact.endpoint_id == self.privacy_request_id
            || self.contact.endpoint_id == self.communication_subject_id
            || !(2..=64).contains(&self.jurisdiction.chars().count())
            || self.jurisdiction.trim() != self.jurisdiction
            || !(1..=100).contains(&self.communication_subject_hmac_key_version.chars().count())
            || self.communication_subject_hmac_key_version.trim()
                != self.communication_subject_hmac_key_version
            || self.communication_subject_hmac_key_version != self.contact.hmac_key_version
            || !(1..=100).contains(&self.receipt_token_key_version.chars().count())
            || self.receipt_token_key_version.trim() != self.receipt_token_key_version
            || self.receipt_token_key_version != self.contact.hmac_key_version
            || self.encrypted_scope.encryption_key_id()
                != self.encrypted_statement.encryption_key_id()
            || self.bff_issuer != "public-web"
        {
            return Err(PrivacyCommandError::InvalidCommand);
        }
        self.scope = self
            .scope
            .validate()
            .map_err(|_| PrivacyCommandError::ScopeInvalid)?;
        self.identity_proof.validate()?;
        self.contact.validate()?;
        let scope_value =
            serde_json::to_value(&self.scope).map_err(|_| PrivacyCommandError::InvalidCommand)?;
        let scope_canonical =
            canonical_json(&scope_value).map_err(|_| PrivacyCommandError::InvalidCommand)?;
        let expected_scope_digest = PrivacyDigest::try_new(sha256_hex(&scope_canonical))
            .map_err(|_| PrivacyCommandError::InvalidCommand)?;
        if self.encrypted_scope.digest() != &expected_scope_digest {
            return Err(PrivacyCommandError::ScopeInvalid);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyCommandReceipt {
    pub transport_request_id: Uuid,
    pub aggregate_id: Uuid,
    pub aggregate_version: i64,
    pub audit_event_id: Uuid,
    pub accepted_at: OffsetDateTime,
    pub receipt_digest: PrivacyDigest,
    pub emitted_event_ids: Vec<Uuid>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreatedPrivacyRequest {
    pub command: PrivacyCommandReceipt,
    pub request: PrivacyRequestSummary,
    pub replayed: bool,
}

impl CreatedPrivacyRequest {
    pub fn validate(self, proposed_request_id: Uuid) -> Result<Self, PrivacyCommandError> {
        if self.command.transport_request_id.is_nil()
            || self.command.aggregate_id != self.request.privacy_request_id
            || !self.replayed && self.command.aggregate_id != proposed_request_id
            || self.command.aggregate_version != 1
            || self.command.audit_event_id.is_nil()
            || self.command.emitted_event_ids.len() != 1
            || self.command.emitted_event_ids[0].is_nil()
            || self.command.emitted_event_ids[0] == self.command.audit_event_id
            || self.command.accepted_at < self.request.created_at
            || self.request.state != PrivacyRequestState::Received
            || self.request.identity_state != PrivacyIdentityState::PendingVerification
            || self.request.identity_verified_at.is_some()
            || self.request.due_at.is_some()
        {
            return Err(PrivacyCommandError::InvalidOwnerResult);
        }
        Ok(self)
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct ExchangePrivacyReceiptToken {
    pub receipt_token_hmac: PrivacyDigest,
    pub next_submission_session_sha256: PrivacyDigest,
    pub transport_request_id: Uuid,
    pub idempotency_key_sha256: PrivacyDigest,
    pub request_sha256: PrivacyDigest,
    pub bff_issuer: String,
}

impl ExchangePrivacyReceiptToken {
    pub fn validate(self) -> Result<Self, PrivacyCommandError> {
        if self.transport_request_id.is_nil() || self.bff_issuer != "public-web" {
            return Err(PrivacyCommandError::InvalidCommand);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyRequestSession {
    pub request_id: Uuid,
    pub session_id: Uuid,
    pub expires_at: OffsetDateTime,
    pub cookie_name: String,
    pub token_consumed_at: OffsetDateTime,
    pub audit_event_id: Uuid,
    pub emitted_event_ids: Vec<Uuid>,
    pub receipt_digest: PrivacyDigest,
    pub replayed: bool,
}

impl PrivacyRequestSession {
    pub fn validate(self) -> Result<Self, PrivacyCommandError> {
        if self.request_id.is_nil()
            || self.session_id.is_nil()
            || self.expires_at <= self.token_consumed_at
            || self.audit_event_id.is_nil()
            || self.emitted_event_ids.len() != 1
            || self.emitted_event_ids[0].is_nil()
            || self.emitted_event_ids[0] == self.audit_event_id
            || self.cookie_name != PRIVACY_REQUEST_RECEIPT_COOKIE_NAME
        {
            return Err(PrivacyCommandError::InvalidOwnerResult);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GetPrivacyRequest {
    pub session_token_sha256: PrivacyDigest,
    pub bff_issuer: String,
}

impl GetPrivacyRequest {
    pub fn validate(self) -> Result<Self, PrivacyCommandError> {
        if self.bff_issuer != "public-web" {
            Err(PrivacyCommandError::InvalidCommand)
        } else {
            Ok(self)
        }
    }
}

pub trait PrivacyRequestRepository {
    type Error: std::error::Error + Send + Sync + 'static;

    fn create<'a>(
        &'a mut self,
        request: &'a CreatePrivacyRequest,
    ) -> PrivacyFuture<'a, CreatedPrivacyRequest, Self::Error>;

    fn exchange<'a>(
        &'a mut self,
        request: &'a ExchangePrivacyReceiptToken,
    ) -> PrivacyFuture<'a, PrivacyRequestSession, Self::Error>;

    fn get<'a>(
        &'a mut self,
        request: &'a GetPrivacyRequest,
    ) -> PrivacyFuture<'a, PrivacyRequestPublicStatus, Self::Error>;
}

pub struct PrivacyRequestUseCase<'a, Repository: ?Sized> {
    repository: &'a mut Repository,
}

impl<'a, Repository> PrivacyRequestUseCase<'a, Repository>
where
    Repository: PrivacyRequestRepository + ?Sized,
{
    pub const fn new(repository: &'a mut Repository) -> Self {
        Self { repository }
    }

    pub async fn create(
        &mut self,
        request: CreatePrivacyRequest,
    ) -> Result<CreatedPrivacyRequest, PrivacyUseCaseError<Repository::Error>> {
        let request = request.validate().map_err(PrivacyUseCaseError::Command)?;
        let proposed_request_id = request.privacy_request_id;
        self.repository
            .create(&request)
            .await
            .map_err(PrivacyUseCaseError::Repository)?
            .validate(proposed_request_id)
            .map_err(PrivacyUseCaseError::Command)
    }

    pub async fn exchange(
        &mut self,
        request: ExchangePrivacyReceiptToken,
    ) -> Result<PrivacyRequestSession, PrivacyUseCaseError<Repository::Error>> {
        let request = request.validate().map_err(PrivacyUseCaseError::Command)?;
        self.repository
            .exchange(&request)
            .await
            .map_err(PrivacyUseCaseError::Repository)
            .and_then(|session| session.validate().map_err(PrivacyUseCaseError::Command))
    }

    pub async fn get(
        &mut self,
        request: GetPrivacyRequest,
    ) -> Result<PrivacyRequestPublicStatus, PrivacyUseCaseError<Repository::Error>> {
        let request = request.validate().map_err(PrivacyUseCaseError::Command)?;
        self.repository
            .get(&request)
            .await
            .map_err(PrivacyUseCaseError::Repository)
            .and_then(|status| status.validate().map_err(PrivacyUseCaseError::Command))
    }
}

#[derive(Clone, Copy, Debug, Eq, thiserror::Error, PartialEq)]
pub enum PrivacyCommandError {
    #[error("privacy command is invalid")]
    InvalidCommand,
    #[error("privacy identity proof is invalid")]
    IdentityProofInvalid,
    #[error("privacy request scope is invalid")]
    ScopeInvalid,
    #[error("privacy owner result violates the closed receipt contract")]
    InvalidOwnerResult,
}

#[derive(Debug, thiserror::Error)]
pub enum PrivacyUseCaseError<RepositoryError> {
    #[error(transparent)]
    Command(#[from] PrivacyCommandError),
    #[error("privacy persistence failed")]
    Repository(RepositoryError),
}

impl From<PrivacyError> for PrivacyCommandError {
    fn from(error: PrivacyError) -> Self {
        match error {
            PrivacyError::InvalidScope => Self::ScopeInvalid,
            _ => Self::InvalidCommand,
        }
    }
}

#[cfg(test)]
#[path = "privacy_tests.rs"]
mod tests;
