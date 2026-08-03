use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroize;

use crate::{
    assertion::canonical::{canonical_json, sha256_hex},
    envelope::{EnvelopeError, EnvelopeKey, EnvelopeKeyRing, decrypt, encrypt},
};

const COOKIE_PREFIX: &str = "gurine-ssc-v1";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SubmissionSessionKind {
    ResponsePending,
    ResponseActive,
    CorrectionDraft,
    SubscriptionPending,
    SubscriptionManagement,
    ResponseReceipt,
    CorrectionReceipt,
}

impl SubmissionSessionKind {
    pub const fn ttl_seconds(self) -> i64 {
        match self {
            Self::ResponsePending => 900,
            Self::ResponseActive => 43_200,
            Self::CorrectionDraft => 86_400,
            Self::SubscriptionPending
            | Self::SubscriptionManagement
            | Self::ResponseReceipt
            | Self::CorrectionReceipt => 1_800,
        }
    }

    pub fn allows(self, operation_id: &str) -> bool {
        match self {
            Self::ResponsePending => matches!(
                operation_id,
                "getResponseAccessStatus" | "verifyResponseAccess"
            ),
            Self::ResponseActive => matches!(
                operation_id,
                "getResponseAccessStatus"
                    | "getResponseRequest"
                    | "downloadResponseRequest"
                    | "getResponseDraft"
                    | "saveResponseDraft"
                    | "createResponseAttachmentUpload"
                    | "finalizeResponseAttachment"
                    | "deleteResponseAttachment"
                    | "getResponseSubmissionPreview"
                    | "requestResponseExtension"
                    | "submitResponse"
            ),
            Self::CorrectionDraft => matches!(
                operation_id,
                "getCorrectionRequestDraft"
                    | "saveCorrectionRequestDraft"
                    | "deleteCorrectionRequestDraft"
                    | "createCorrectionAttachment"
                    | "finalizeCorrectionAttachment"
                    | "deleteCorrectionAttachment"
                    | "getCorrectionRequestDraftPreview"
                    | "createCorrectionRequest"
            ),
            Self::SubscriptionPending => false,
            Self::SubscriptionManagement => matches!(
                operation_id,
                "getSubscription" | "updateSubscription" | "unsubscribe"
            ),
            Self::ResponseReceipt => operation_id == "getResponseReceipt",
            Self::CorrectionReceipt => operation_id == "getCorrectionReceipt",
        }
    }

    pub const fn cookie(self) -> CookieBinding {
        match self {
            Self::ResponsePending | Self::ResponseActive => CookieBinding {
                name: "gurine_response_session",
                path: "/respond",
            },
            Self::CorrectionDraft => CookieBinding {
                name: "gurine_correction_session",
                path: "/correction-request",
            },
            Self::SubscriptionPending | Self::SubscriptionManagement => CookieBinding {
                name: "gurine_subscription_session",
                path: "/subscription",
            },
            Self::ResponseReceipt => CookieBinding {
                name: "gurine_response_receipt_session",
                path: "/respond/receipt",
            },
            Self::CorrectionReceipt => CookieBinding {
                name: "gurine_correction_receipt_session",
                path: "/correction-request/receipt",
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CookieBinding {
    pub name: &'static str,
    pub path: &'static str,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SubmissionSessionCookiePayload {
    pub absolute_expires_at: i64,
    pub csrf_rotated_at: i64,
    pub csrf_token: String,
    pub issued_at: i64,
    pub opaque_session_token: String,
    pub session_kind: SubmissionSessionKind,
    pub typ: String,
    pub v: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SubmissionSessionStatus {
    Active,
    Consumed,
    Revoked,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SubmissionSession {
    pub id: Uuid,
    pub token_hash: String,
    pub kind: SubmissionSessionKind,
    pub scope_id: Uuid,
    pub bff_issuer: String,
    pub expires_at: i64,
    pub version: i64,
    pub status: SubmissionSessionStatus,
}

pub struct IssuedSubmissionSession {
    pub session: SubmissionSession,
    pub token: OpaqueToken,
}

pub struct OpaqueToken(String);

impl OpaqueToken {
    pub fn generate() -> Result<Self, SubmissionSessionError> {
        let mut bytes = [0_u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| SubmissionSessionError::RandomnessUnavailable)?;
        let token = URL_SAFE_NO_PAD.encode(bytes);
        bytes.zeroize();
        Ok(Self(token))
    }

    pub fn expose_for_bff_sealing(&self) -> &str {
        &self.0
    }

    pub fn sha256(&self) -> String {
        sha256_hex(self.0.as_bytes())
    }
}

impl Drop for OpaqueToken {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum SubmissionSessionError {
    #[error("operating system randomness is unavailable")]
    RandomnessUnavailable,
    #[error("submission session is invalid, expired, consumed, revoked, or out of scope")]
    InvalidSession,
    #[error("operation is not allowed for the submission session kind")]
    OperationDenied,
    #[error("submission session transition is invalid")]
    InvalidTransition,
    #[error("submission session cookie is invalid")]
    InvalidCookie,
}

impl SubmissionSession {
    pub fn issue(
        kind: SubmissionSessionKind,
        scope_id: Uuid,
        bff_issuer: &str,
        now: i64,
    ) -> Result<IssuedSubmissionSession, SubmissionSessionError> {
        if !matches!(bff_issuer, "public-web" | "response-portal") {
            return Err(SubmissionSessionError::InvalidSession);
        }
        let token = OpaqueToken::generate()?;
        let session = Self {
            id: Uuid::new_v4(),
            token_hash: token.sha256(),
            kind,
            scope_id,
            bff_issuer: bff_issuer.to_owned(),
            expires_at: now + kind.ttl_seconds(),
            version: 1,
            status: SubmissionSessionStatus::Active,
        };
        Ok(IssuedSubmissionSession { session, token })
    }

    pub fn authorize(
        &self,
        raw_token: &str,
        bff_issuer: &str,
        scope_id: Uuid,
        operation_id: &str,
        now: i64,
    ) -> Result<(), SubmissionSessionError> {
        let candidate_hash = sha256_hex(raw_token.as_bytes());
        if self.status != SubmissionSessionStatus::Active
            || now >= self.expires_at
            || self.scope_id != scope_id
            || self.bff_issuer != bff_issuer
            || !constant_time_equal(&candidate_hash, &self.token_hash)
        {
            return Err(SubmissionSessionError::InvalidSession);
        }
        if !self.kind.allows(operation_id) {
            return Err(SubmissionSessionError::OperationDenied);
        }
        Ok(())
    }

    pub fn consume_and_rotate(
        &mut self,
        next_kind: SubmissionSessionKind,
        now: i64,
    ) -> Result<IssuedSubmissionSession, SubmissionSessionError> {
        if self.status != SubmissionSessionStatus::Active
            || !allowed_transition(self.kind, next_kind)
        {
            return Err(SubmissionSessionError::InvalidTransition);
        }
        self.status = SubmissionSessionStatus::Consumed;
        self.version += 1;
        Self::issue(next_kind, self.scope_id, &self.bff_issuer, now)
    }

    pub fn revoke(&mut self) -> Result<(), SubmissionSessionError> {
        if self.status != SubmissionSessionStatus::Active {
            return Err(SubmissionSessionError::InvalidTransition);
        }
        self.status = SubmissionSessionStatus::Revoked;
        self.version += 1;
        Ok(())
    }
}

pub fn seal_cookie(
    key: &EnvelopeKey,
    origin: &str,
    payload: &SubmissionSessionCookiePayload,
) -> Result<String, SubmissionSessionError> {
    validate_cookie(payload, payload.issued_at)?;
    let binding = payload.session_kind.cookie();
    let plaintext = canonical_json(payload).map_err(|_| SubmissionSessionError::InvalidCookie)?;
    encrypt(
        COOKIE_PREFIX,
        key,
        &[COOKIE_PREFIX, binding.name, origin, binding.path, "Lax"],
        &plaintext,
    )
    .map_err(map_envelope)
}

pub fn open_cookie(
    keys: &EnvelopeKeyRing,
    origin: &str,
    expected_kind: SubmissionSessionKind,
    token: &str,
    now: i64,
) -> Result<SubmissionSessionCookiePayload, SubmissionSessionError> {
    let binding = expected_kind.cookie();
    let plaintext = decrypt(
        COOKIE_PREFIX,
        keys,
        &[COOKIE_PREFIX, binding.name, origin, binding.path, "Lax"],
        token,
    )
    .map_err(map_envelope)?;
    let payload: SubmissionSessionCookiePayload =
        serde_json::from_slice(&plaintext).map_err(|_| SubmissionSessionError::InvalidCookie)?;
    if payload.session_kind != expected_kind
        || canonical_json(&payload).map_err(|_| SubmissionSessionError::InvalidCookie)? != plaintext
    {
        return Err(SubmissionSessionError::InvalidCookie);
    }
    validate_cookie(&payload, now)?;
    Ok(payload)
}

fn allowed_transition(from: SubmissionSessionKind, to: SubmissionSessionKind) -> bool {
    matches!(
        (from, to),
        (
            SubmissionSessionKind::ResponsePending,
            SubmissionSessionKind::ResponseActive
        ) | (
            SubmissionSessionKind::ResponseActive,
            SubmissionSessionKind::ResponseReceipt
        ) | (
            SubmissionSessionKind::CorrectionDraft,
            SubmissionSessionKind::CorrectionReceipt
        ) | (
            SubmissionSessionKind::SubscriptionPending,
            SubmissionSessionKind::SubscriptionManagement
        )
    )
}

fn validate_cookie(
    payload: &SubmissionSessionCookiePayload,
    now: i64,
) -> Result<(), SubmissionSessionError> {
    if payload.v != 1
        || payload.typ != "submission-session"
        || !(43..=128).contains(&payload.opaque_session_token.len())
        || !(43..=128).contains(&payload.csrf_token.len())
        || payload.issued_at > payload.csrf_rotated_at
        || payload.csrf_rotated_at > payload.absolute_expires_at
        || now >= payload.absolute_expires_at
        || payload.absolute_expires_at - payload.issued_at > payload.session_kind.ttl_seconds()
        || !base64url_token(&payload.opaque_session_token)
        || !base64url_token(&payload.csrf_token)
    {
        return Err(SubmissionSessionError::InvalidCookie);
    }
    Ok(())
}

fn base64url_token(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn constant_time_equal(left: &str, right: &str) -> bool {
    left.len() == right.len() && bool::from(left.as_bytes().ct_eq(right.as_bytes()))
}

fn map_envelope(_error: EnvelopeError) -> SubmissionSessionError {
    SubmissionSessionError::InvalidCookie
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn response_session_cannot_cross_scope_or_operation() -> Result<(), SubmissionSessionError> {
        let scope = Uuid::new_v4();
        let issued = SubmissionSession::issue(
            SubmissionSessionKind::ResponseActive,
            scope,
            "response-portal",
            100,
        )?;
        let token = issued.token.expose_for_bff_sealing();
        issued
            .session
            .authorize(token, "response-portal", scope, "saveResponseDraft", 101)?;
        assert_eq!(
            issued.session.authorize(
                token,
                "response-portal",
                Uuid::new_v4(),
                "saveResponseDraft",
                101
            ),
            Err(SubmissionSessionError::InvalidSession)
        );
        assert_eq!(
            issued.session.authorize(
                token,
                "response-portal",
                scope,
                "getCorrectionRequestDraft",
                101
            ),
            Err(SubmissionSessionError::OperationDenied)
        );
        Ok(())
    }
}
