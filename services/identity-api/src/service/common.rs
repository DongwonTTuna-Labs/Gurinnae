use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use gurine_auth::{assertion::canonical::sha256_hex, oidc::TransactionKind};
use gurine_persistence_postgres::identity::{
    ClaimedOidcTransaction, RequestContext as PersistenceContext, ResolvedSession, resolve_session,
    session_context_matches,
};
use openidconnect::{
    AuthorizationCode, ClientId, ClientSecret, PkceCodeVerifier, RedirectUrl, core::CoreClient,
};
use thiserror::Error;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use zeroize::Zeroize;

use crate::{dto, state::AppState};

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("request is invalid")]
    InvalidRequest,
    #[error("OIDC callback binding is invalid")]
    CallbackBinding,
    #[error("OIDC provider is unavailable")]
    OidcUnavailable,
    #[error("OIDC token validation failed")]
    OidcValidation,
    #[error("session is not active")]
    SessionNotActive,
    #[error("CSRF token is invalid")]
    CsrfInvalid,
    #[error("capability is denied")]
    CapabilityDenied,
    #[error("assurance level is insufficient")]
    AssuranceInsufficient,
    #[error("request conflicts with stored state")]
    Conflict,
    #[error("persistence is unavailable")]
    Persistence,
    #[error("cryptographic operation failed")]
    Cryptography,
}

pub struct VerifiedOidcIdentity {
    pub subject: String,
    pub auth_time: i64,
}

pub async fn exchange_identity(
    state: &AppState,
    claimed: &ClaimedOidcTransaction,
    code: &str,
) -> Result<VerifiedOidcIdentity, ServiceError> {
    let verifier = gurine_auth::oidc::decrypt_pkce_verifier(
        &state.field_keys,
        claimed.id,
        &claimed.pkce_verifier_encrypted,
    )?;
    let token_endpoint = state
        .oidc_provider
        .token_endpoint()
        .cloned()
        .ok_or(ServiceError::OidcUnavailable)?;
    let redirect =
        RedirectUrl::new(claimed.redirect_uri.clone()).map_err(|_| ServiceError::OidcValidation)?;
    let client = CoreClient::from_provider_metadata(
        state.oidc_provider.clone(),
        ClientId::new(state.config.oidc_client_id.clone()),
        Some(ClientSecret::new(state.config.oidc_client_secret.clone())),
    )
    .set_token_uri(token_endpoint)
    .set_redirect_uri(redirect);
    let response = client
        .exchange_code(AuthorizationCode::new(code.to_owned()))
        .set_pkce_verifier(PkceCodeVerifier::new(verifier))
        .request_async(&state.oidc_http)
        .await
        .map_err(|_| ServiceError::OidcUnavailable)?;
    let id_token = response
        .extra_fields()
        .id_token()
        .ok_or(ServiceError::OidcValidation)?;
    let expected_nonce_hash = claimed.nonce_hash.clone();
    let claims = id_token
        .claims(
            &client.id_token_verifier(),
            move |nonce: Option<&openidconnect::Nonce>| {
                if nonce.is_some_and(|value| {
                    sha256_hex(value.secret().as_bytes()) == expected_nonce_hash
                }) {
                    Ok(())
                } else {
                    Err("nonce mismatch".to_owned())
                }
            },
        )
        .map_err(|_| ServiceError::OidcValidation)?;
    if claimed.kind == TransactionKind::StepUp
        && state
            .config
            .oidc_acr_values
            .as_deref()
            .is_some_and(|required| {
                claims.auth_context_ref().map(AsRef::<str>::as_ref) != Some(required)
            })
    {
        return Err(ServiceError::AssuranceInsufficient);
    }
    let auth_time = claims.auth_time().map_or_else(
        || claims.issue_time().timestamp(),
        |value| value.timestamp(),
    );
    Ok(VerifiedOidcIdentity {
        subject: claims.subject().as_str().to_owned(),
        auth_time,
    })
}

pub async fn bound_session(
    state: &AppState,
    token: &str,
    context: &dto::RequestContext,
) -> Result<ResolvedSession, ServiceError> {
    if !context.valid() {
        return Err(ServiceError::InvalidRequest);
    }
    let token_hash = sha256_hex(token.as_bytes());
    let session = resolve_session(&state.pool, &token_hash)
        .await
        .map_err(|_| ServiceError::Persistence)?
        .ok_or(ServiceError::SessionNotActive)?;
    let matches = session_context_matches(
        &state.pool,
        &token_hash,
        &PersistenceContext {
            ip_hash: &context.ip_hash,
            user_agent_hash: &context.user_agent_hash,
        },
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    if !matches {
        return Err(ServiceError::SessionNotActive);
    }
    Ok(session)
}

pub fn actor(session: &ResolvedSession) -> dto::ActorIdentity {
    dto::ActorIdentity {
        user_id: session.user_id,
        email: session.email.clone(),
        display_name: session.display_name.clone(),
        role_codes: session.role_codes.clone(),
        capabilities: session.capabilities.clone(),
    }
}

pub fn random_token() -> Result<String, ServiceError> {
    let mut value = [0_u8; 32];
    getrandom::fill(&mut value).map_err(|_| ServiceError::Cryptography)?;
    let token = URL_SAFE_NO_PAD.encode(value);
    value.zeroize();
    Ok(token)
}

pub fn timestamp(value: OffsetDateTime) -> Result<String, ServiceError> {
    value
        .format(&Rfc3339)
        .map_err(|_| ServiceError::InvalidRequest)
}

pub fn request_context_hash(context: &dto::RequestContext) -> String {
    sha256_hex(
        format!(
            "{}\n{}\n{}",
            context.ip_hash, context.user_agent_hash, context.request_id
        )
        .as_bytes(),
    )
}

pub fn ensure_callback(
    supplied: &str,
    expected: &str,
    allow_insecure: bool,
) -> Result<(), ServiceError> {
    let supplied = url::Url::parse(supplied).map_err(|_| ServiceError::InvalidRequest)?;
    let expected = url::Url::parse(expected).map_err(|_| ServiceError::InvalidRequest)?;
    if supplied != expected || (!allow_insecure && supplied.scheme() != "https") {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

pub fn ensure_callback_cookie(cookie: &str, state_value: &str) -> Result<(), ServiceError> {
    if cookie.is_empty() || sha256_hex(cookie.as_bytes()) != sha256_hex(state_value.as_bytes()) {
        return Err(ServiceError::CallbackBinding);
    }
    Ok(())
}

impl From<gurine_auth::oidc::OidcError> for ServiceError {
    fn from(_: gurine_auth::oidc::OidcError) -> Self {
        ServiceError::Cryptography
    }
}
