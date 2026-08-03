use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use thiserror::Error;
use url::Url;
use uuid::Uuid;
use zeroize::Zeroize;

use crate::{
    assertion::canonical::sha256_hex,
    envelope::{EnvelopeError, EnvelopeKey, EnvelopeKeyRing, decrypt, encrypt},
};

const TRANSACTION_TTL_SECONDS: i64 = 600;
const PKCE_PREFIX: &str = "gurine-oidc-pkce-v1";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum TransactionKind {
    Login,
    StepUp,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ActionAuthorizationContext {
    pub operation_id: String,
    pub aggregate_type: String,
    pub aggregate_id: String,
    pub expected_version: Option<i64>,
    pub business_payload_sha256: String,
    pub idempotency_key_sha256: String,
}

impl ActionAuthorizationContext {
    pub fn digest(&self) -> Result<String, OidcError> {
        let value = serde_json::to_value(self).map_err(|_| OidcError::InvalidActionContext)?;
        let bytes = crate::assertion::canonical::canonical_json(&value)
            .map_err(|_| OidcError::InvalidActionContext)?;
        Ok(sha256_hex(&bytes))
    }

    pub fn validate(&self) -> Result<(), OidcError> {
        if self.operation_id.is_empty()
            || self.aggregate_type.is_empty()
            || self.aggregate_id.is_empty()
            || self.aggregate_id.len() > 200
            || !is_hash(&self.business_payload_sha256)
            || !is_hash(&self.idempotency_key_sha256)
            || self.expected_version.is_some_and(|version| version < 1)
        {
            return Err(OidcError::InvalidActionContext);
        }
        Ok(())
    }
}

pub struct OidcTransaction {
    pub id: Uuid,
    pub kind: TransactionKind,
    pub state_hash: String,
    pub nonce_hash: String,
    pub safe_return_to: String,
    pub session_id: Option<Uuid>,
    pub action_context: Option<ActionAuthorizationContext>,
    pub action_digest: Option<String>,
    pub idempotency_key_sha256: Option<String>,
    pub issued_at: i64,
    pub expires_at: i64,
    state: String,
    nonce: String,
    pkce_verifier: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizationRequest {
    pub url: Url,
    pub transaction_cookie_value: String,
}

#[derive(Clone, Copy)]
pub struct ProviderConfig<'a> {
    pub issuer: &'a str,
    pub authorization_endpoint: &'a str,
    pub client_id: &'a str,
    pub redirect_uri: &'a str,
    pub scopes: &'a str,
    pub acr_values: Option<&'a str>,
    pub allow_insecure_test_issuer: bool,
}

#[derive(Clone, Copy)]
pub struct CallbackInput<'a> {
    pub state: &'a str,
    pub issuer: Option<&'a str>,
    pub expected_issuer: &'a str,
    pub now: i64,
    pub session_id: Option<Uuid>,
    pub action_digest: Option<&'a str>,
    pub idempotency_key_sha256: Option<&'a str>,
}

#[derive(Clone, Copy)]
pub struct VerifiedIdToken<'a> {
    pub issuer: &'a str,
    pub audience: &'a str,
    pub subject: &'a str,
    pub nonce: &'a str,
    pub expires_at: i64,
    pub issued_at: i64,
    pub auth_time: i64,
    pub acr: Option<&'a str>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VerifiedIdentity<'a> {
    pub subject: &'a str,
    pub auth_time: i64,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum OidcError {
    #[error("operating system randomness is unavailable")]
    RandomnessUnavailable,
    #[error("OIDC provider configuration is invalid")]
    InvalidProviderConfiguration,
    #[error("return target is not allowlisted")]
    UnsafeReturnTarget,
    #[error("step-up action context is invalid")]
    InvalidActionContext,
    #[error("OIDC transaction has expired")]
    TransactionExpired,
    #[error("OIDC callback state does not match")]
    StateMismatch,
    #[error("OIDC callback issuer does not match")]
    IssuerMismatch,
    #[error("OIDC callback binding does not match")]
    CallbackBindingMismatch,
    #[error("OIDC ID token claims do not match the transaction")]
    IdTokenMismatch,
    #[error("OIDC step-up assurance is insufficient")]
    InsufficientAcr,
    #[error("encrypted PKCE verifier is invalid")]
    PkceEnvelopeInvalid,
}

impl OidcTransaction {
    pub fn login(return_to: Option<&str>, now: i64) -> Result<Self, OidcError> {
        Self::new(
            TransactionKind::Login,
            safe_return_target(return_to)?,
            None,
            None,
            now,
        )
    }

    pub fn step_up(
        return_to: Option<&str>,
        session_id: Uuid,
        action_context: ActionAuthorizationContext,
        now: i64,
    ) -> Result<Self, OidcError> {
        action_context.validate()?;
        Self::new(
            TransactionKind::StepUp,
            safe_return_target(return_to)?,
            Some(session_id),
            Some(action_context),
            now,
        )
    }

    fn new(
        kind: TransactionKind,
        safe_return_to: String,
        session_id: Option<Uuid>,
        action_context: Option<ActionAuthorizationContext>,
        now: i64,
    ) -> Result<Self, OidcError> {
        let state = random_token(32)?;
        let nonce = random_token(32)?;
        let pkce_verifier = random_token(64)?;
        let action_digest = action_context
            .as_ref()
            .map(ActionAuthorizationContext::digest)
            .transpose()?;
        let idempotency_key_sha256 = action_context
            .as_ref()
            .map(|context| context.idempotency_key_sha256.clone());
        Ok(Self {
            id: Uuid::new_v4(),
            kind,
            state_hash: sha256_hex(state.as_bytes()),
            nonce_hash: sha256_hex(nonce.as_bytes()),
            safe_return_to,
            session_id,
            action_context,
            action_digest,
            idempotency_key_sha256,
            issued_at: now,
            expires_at: now + TRANSACTION_TTL_SECONDS,
            state,
            nonce,
            pkce_verifier,
        })
    }

    pub fn authorization_request(
        &self,
        provider: ProviderConfig<'_>,
    ) -> Result<AuthorizationRequest, OidcError> {
        validate_provider(provider)?;
        let mut url = Url::parse(provider.authorization_endpoint)
            .map_err(|_| OidcError::InvalidProviderConfiguration)?;
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(self.pkce_verifier.as_bytes()));
        {
            let mut query = url.query_pairs_mut();
            query
                .append_pair("response_type", "code")
                .append_pair("client_id", provider.client_id)
                .append_pair("redirect_uri", provider.redirect_uri)
                .append_pair("scope", provider.scopes)
                .append_pair("state", &self.state)
                .append_pair("nonce", &self.nonce)
                .append_pair("code_challenge", &challenge)
                .append_pair("code_challenge_method", "S256");
            if self.kind == TransactionKind::StepUp {
                query
                    .append_pair("max_age", "0")
                    .append_pair("prompt", "login");
                if let Some(acr_values) = provider.acr_values {
                    query.append_pair("acr_values", acr_values);
                }
            }
        }
        Ok(AuthorizationRequest {
            url,
            transaction_cookie_value: self.state.clone(),
        })
    }

    pub fn encrypted_pkce_verifier(&self, key: &EnvelopeKey) -> Result<Vec<u8>, OidcError> {
        encrypt(
            PKCE_PREFIX,
            key,
            &[self.id.to_string().as_str(), "pkce_verifier_encrypted"],
            self.pkce_verifier.as_bytes(),
        )
        .map(String::into_bytes)
        .map_err(|_| OidcError::PkceEnvelopeInvalid)
    }

    pub fn validate_callback(&self, input: CallbackInput<'_>) -> Result<(), OidcError> {
        if input.now > self.expires_at {
            return Err(OidcError::TransactionExpired);
        }
        if !constant_time_hash_matches(input.state, &self.state_hash) {
            return Err(OidcError::StateMismatch);
        }
        if input
            .issuer
            .is_some_and(|issuer| issuer != input.expected_issuer)
        {
            return Err(OidcError::IssuerMismatch);
        }
        if self.session_id != input.session_id
            || self.action_digest.as_deref() != input.action_digest
            || self.idempotency_key_sha256.as_deref() != input.idempotency_key_sha256
        {
            return Err(OidcError::CallbackBindingMismatch);
        }
        Ok(())
    }

    pub fn verify_id_token<'a>(
        &self,
        token: VerifiedIdToken<'a>,
        provider: ProviderConfig<'_>,
        now: i64,
    ) -> Result<VerifiedIdentity<'a>, OidcError> {
        if token.issuer != provider.issuer
            || token.audience != provider.client_id
            || !constant_time_hash_matches(token.nonce, &self.nonce_hash)
            || token.expires_at < now
            || token.issued_at > now + 5
            || token.auth_time > now + 5
            || token.subject.is_empty()
        {
            return Err(OidcError::IdTokenMismatch);
        }
        if self.kind == TransactionKind::StepUp
            && provider
                .acr_values
                .is_some_and(|required| token.acr != Some(required))
        {
            return Err(OidcError::InsufficientAcr);
        }
        Ok(VerifiedIdentity {
            subject: token.subject,
            auth_time: token.auth_time,
        })
    }
}

impl Drop for OidcTransaction {
    fn drop(&mut self) {
        self.state.zeroize();
        self.nonce.zeroize();
        self.pkce_verifier.zeroize();
    }
}

pub fn decrypt_pkce_verifier(
    keys: &EnvelopeKeyRing,
    transaction_id: Uuid,
    ciphertext: &[u8],
) -> Result<String, OidcError> {
    let token = std::str::from_utf8(ciphertext).map_err(|_| OidcError::PkceEnvelopeInvalid)?;
    let transaction_id = transaction_id.to_string();
    let plaintext = decrypt(
        PKCE_PREFIX,
        keys,
        &[&transaction_id, "pkce_verifier_encrypted"],
        token,
    )
    .map_err(map_envelope)?;
    String::from_utf8(plaintext).map_err(|_| OidcError::PkceEnvelopeInvalid)
}

pub fn safe_return_target(candidate: Option<&str>) -> Result<String, OidcError> {
    let value = candidate.unwrap_or("/internal");
    let lowercase = value.to_ascii_lowercase();
    if !value.starts_with("/internal")
        || value.starts_with("//")
        || value.contains('\\')
        || value.contains('#')
        || lowercase.contains("%2f")
        || lowercase.contains("%5c")
        || value
            .split(['/', '?'])
            .any(|segment| segment == ".." || segment == ".")
    {
        return Err(OidcError::UnsafeReturnTarget);
    }
    Ok(value.to_owned())
}

fn validate_provider(provider: ProviderConfig<'_>) -> Result<(), OidcError> {
    let issuer =
        Url::parse(provider.issuer).map_err(|_| OidcError::InvalidProviderConfiguration)?;
    let authorization = Url::parse(provider.authorization_endpoint)
        .map_err(|_| OidcError::InvalidProviderConfiguration)?;
    let redirect =
        Url::parse(provider.redirect_uri).map_err(|_| OidcError::InvalidProviderConfiguration)?;
    let secure = |url: &Url| url.scheme() == "https" || provider.allow_insecure_test_issuer;
    if !secure(&issuer)
        || !secure(&authorization)
        || !secure(&redirect)
        || provider.client_id.is_empty()
        || provider
            .scopes
            .split_whitespace()
            .all(|scope| scope != "openid")
    {
        return Err(OidcError::InvalidProviderConfiguration);
    }
    Ok(())
}

fn random_token(bytes: usize) -> Result<String, OidcError> {
    let mut value = vec![0_u8; bytes];
    getrandom::fill(&mut value).map_err(|_| OidcError::RandomnessUnavailable)?;
    let token = URL_SAFE_NO_PAD.encode(&value);
    value.zeroize();
    Ok(token)
}

fn constant_time_hash_matches(candidate: &str, expected_hash: &str) -> bool {
    let candidate_hash = sha256_hex(candidate.as_bytes());
    bool::from(candidate_hash.as_bytes().ct_eq(expected_hash.as_bytes()))
}

fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn map_envelope(_error: EnvelopeError) -> OidcError {
    OidcError::PkceEnvelopeInvalid
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> ActionAuthorizationContext {
        ActionAuthorizationContext {
            operation_id: "activateRuleVersion".to_owned(),
            aggregate_type: "core.rule_version".to_owned(),
            aggregate_id: Uuid::new_v4().to_string(),
            idempotency_key_sha256: "2".repeat(64),
            expected_version: Some(1),
            business_payload_sha256: "1".repeat(64),
        }
    }

    #[test]
    fn step_up_callback_is_bound_to_session_action_and_idempotency() -> Result<(), OidcError> {
        let session_id = Uuid::new_v4();
        let transaction =
            OidcTransaction::step_up(Some("/internal/rules"), session_id, context(), 100)?;
        let input = CallbackInput {
            state: &transaction.state,
            issuer: Some("https://issuer.example"),
            expected_issuer: "https://issuer.example",
            now: 200,
            session_id: Some(session_id),
            action_digest: transaction.action_digest.as_deref(),
            idempotency_key_sha256: transaction.idempotency_key_sha256.as_deref(),
        };
        transaction.validate_callback(input)
    }

    #[test]
    fn action_digest_uses_the_cross_language_key_sorted_contract() -> Result<(), OidcError> {
        let context = ActionAuthorizationContext {
            operation_id: "activateRuleVersion".to_owned(),
            aggregate_type: "core.rule_version".to_owned(),
            aggregate_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            expected_version: Some(7),
            business_payload_sha256: "1".repeat(64),
            idempotency_key_sha256: "2".repeat(64),
        };
        let canonical = format!(
            "{{\"aggregateId\":\"11111111-1111-4111-8111-111111111111\",\"aggregateType\":\"core.rule_version\",\"businessPayloadSha256\":\"{}\",\"expectedVersion\":7,\"idempotencyKeySha256\":\"{}\",\"operationId\":\"activateRuleVersion\"}}",
            "1".repeat(64),
            "2".repeat(64),
        );
        assert_eq!(context.digest()?, sha256_hex(canonical.as_bytes()));
        Ok(())
    }

    #[test]
    fn external_return_target_is_rejected() {
        assert_eq!(
            safe_return_target(Some("https://evil.example")),
            Err(OidcError::UnsafeReturnTarget)
        );
        assert_eq!(
            safe_return_target(Some("//evil.example")),
            Err(OidcError::UnsafeReturnTarget)
        );
    }

    #[test]
    fn insecure_redirect_is_limited_to_explicit_test_mode() -> Result<(), OidcError> {
        let transaction = OidcTransaction::login(None, 100)?;
        let provider = ProviderConfig {
            issuer: "http://oidc-test-provider:8085",
            authorization_endpoint: "http://oidc-test-provider:8085/authorize",
            client_id: "gurine-review",
            redirect_uri: "http://127.0.0.1:3001/auth/callback",
            scopes: "openid profile email",
            acr_values: None,
            allow_insecure_test_issuer: true,
        };
        assert!(transaction.authorization_request(provider).is_ok());
        assert!(
            transaction
                .authorization_request(ProviderConfig {
                    allow_insecure_test_issuer: false,
                    ..provider
                })
                .is_err()
        );
        Ok(())
    }
}
