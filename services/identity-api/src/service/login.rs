use gurine_auth::{
    assertion::canonical::sha256_hex,
    oidc::{OidcTransaction, ProviderConfig, TransactionKind},
};
use gurine_persistence_postgres::identity::{
    NewSession, OidcPersistence, RequestContext as PersistenceContext, active_user_by_subject,
    claim_oidc_transaction, create_session, insert_oidc_transaction, resolve_session,
    rotate_csrf_for_session, set_step_up_time,
};
use time::{Duration, OffsetDateTime};

use crate::{dto, state::AppState};

use super::common::{
    ServiceError, actor, bound_session, ensure_callback, ensure_callback_cookie, exchange_identity,
    random_token, request_context_hash, timestamp,
};

pub async fn create_login_transaction(
    state: &AppState,
    request: dto::CreateLoginTransactionRequest,
) -> Result<dto::CreateLoginTransactionResponse, ServiceError> {
    ensure_callback(
        &request.callback_uri,
        &state.config.oidc_redirect_uri,
        state.config.allow_insecure_oidc,
    )?;
    if !request.context.valid() {
        return Err(ServiceError::InvalidRequest);
    }
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let transaction = OidcTransaction::login(Some(&request.return_to), now)?;
    let encrypted_verifier = transaction.encrypted_pkce_verifier(&state.field_keys.current)?;
    insert_oidc_transaction(
        &state.pool,
        &transaction,
        OidcPersistence {
            encrypted_pkce_verifier: &encrypted_verifier,
            issuer_url: &state.config.oidc_issuer_url,
            redirect_uri: &request.callback_uri,
            requested_acr_values: &[],
            max_age_seconds: None,
            request_context_hash: &request_context_hash(&request.context),
        },
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    let provider = provider_config(state, &request.callback_uri, None);
    let authorization = transaction.authorization_request(provider)?;
    Ok(dto::CreateLoginTransactionResponse {
        transaction_cookie_value: authorization.transaction_cookie_value,
        authorization_url: authorization.url.to_string(),
        expires_at: timestamp(
            OffsetDateTime::from_unix_timestamp(transaction.expires_at)
                .map_err(|_| ServiceError::InvalidRequest)?,
        )?,
        same_site: "Lax",
        http_only: true,
        secure: !state.config.allow_insecure_oidc,
        path: "/auth/callback",
        domain_mode: "HOST_ONLY",
    })
}

pub async fn consume_login_callback(
    state: &AppState,
    request: dto::ConsumeLoginCallbackRequest,
) -> Result<dto::ConsumeLoginCallbackResponse, ServiceError> {
    ensure_callback_cookie(&request.transaction_cookie_value, &request.state)?;
    if !request.context.valid() || request.code.is_empty() {
        return Err(ServiceError::InvalidRequest);
    }
    if request
        .issuer
        .as_deref()
        .is_some_and(|issuer| issuer != state.config.oidc_issuer_url)
    {
        return Err(ServiceError::CallbackBinding);
    }
    let claimed = claim_oidc_transaction(&state.pool, &sha256_hex(request.state.as_bytes()))
        .await
        .map_err(|_| ServiceError::Persistence)?
        .ok_or(ServiceError::Conflict)?;
    if claimed.kind != TransactionKind::Login
        || claimed.expires_at <= OffsetDateTime::now_utc()
        || claimed.issuer_url != state.config.oidc_issuer_url
    {
        return Err(ServiceError::CallbackBinding);
    }
    let identity = exchange_identity(state, &claimed, &request.code).await?;
    let (user_id, _, _) = active_user_by_subject(&state.pool, &identity.subject)
        .await
        .map_err(|_| ServiceError::Persistence)?
        .ok_or(ServiceError::SessionNotActive)?;
    let opaque_session_token = random_token()?;
    let csrf_token = random_token()?;
    let session_token_hash = sha256_hex(opaque_session_token.as_bytes());
    let expires_at =
        OffsetDateTime::now_utc() + Duration::seconds(state.config.session_absolute_ttl_seconds);
    create_session(
        &state.pool,
        NewSession {
            user_id,
            session_token_hash: &session_token_hash,
            csrf_token_hash: &sha256_hex(csrf_token.as_bytes()),
            oidc_session_id: None,
            auth_time: OffsetDateTime::from_unix_timestamp(identity.auth_time)
                .map_err(|_| ServiceError::OidcValidation)?,
            expires_at,
            context: PersistenceContext {
                ip_hash: &request.context.ip_hash,
                user_agent_hash: &request.context.user_agent_hash,
            },
        },
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    let session = resolve_session(&state.pool, &session_token_hash)
        .await
        .map_err(|_| ServiceError::Persistence)?
        .ok_or(ServiceError::Persistence)?;
    Ok(dto::ConsumeLoginCallbackResponse {
        opaque_session_token,
        csrf_token,
        return_to: claimed.safe_return_to,
        expires_at: timestamp(expires_at)?,
        actor: actor(&session),
        session_cookie_path: "/",
        session_cookie_domain_mode: "HOST_ONLY",
        session_cookie_same_site: "Lax",
        csrf_storage: "SEALED_BFF_SESSION_SYNCHRONIZER",
    })
}

pub async fn create_step_up_transaction(
    state: &AppState,
    request: dto::CreateStepUpTransactionRequest,
) -> Result<dto::CreateStepUpTransactionResponse, ServiceError> {
    ensure_callback(
        &request.callback_uri,
        &state.config.oidc_step_up_redirect_uri,
        state.config.allow_insecure_oidc,
    )?;
    request.action_context.validate()?;
    let session = bound_session(state, &request.opaque_session_token, &request.context).await?;
    let token_hash = sha256_hex(request.opaque_session_token.as_bytes());
    let csrf_matches = gurine_persistence_postgres::identity::session_csrf_matches(
        &state.pool,
        &token_hash,
        &sha256_hex(request.csrf_token.as_bytes()),
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    if !csrf_matches {
        return Err(ServiceError::CsrfInvalid);
    }
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let transaction = OidcTransaction::step_up(
        Some(&request.return_to),
        session.session_id,
        request.action_context,
        now,
    )?;
    let encrypted_verifier = transaction.encrypted_pkce_verifier(&state.field_keys.current)?;
    let acr_values = state
        .config
        .oidc_acr_values
        .clone()
        .into_iter()
        .collect::<Vec<_>>();
    insert_oidc_transaction(
        &state.pool,
        &transaction,
        OidcPersistence {
            encrypted_pkce_verifier: &encrypted_verifier,
            issuer_url: &state.config.oidc_issuer_url,
            redirect_uri: &request.callback_uri,
            requested_acr_values: &acr_values,
            max_age_seconds: Some(state.config.oidc_step_up_max_age_seconds as i32),
            request_context_hash: &request_context_hash(&request.context),
        },
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    let provider = provider_config(
        state,
        &request.callback_uri,
        state.config.oidc_acr_values.as_deref(),
    );
    let authorization = transaction.authorization_request(provider)?;
    Ok(dto::CreateStepUpTransactionResponse {
        transaction_cookie_value: authorization.transaction_cookie_value,
        authorization_url: authorization.url.to_string(),
        expires_at: timestamp(
            OffsetDateTime::from_unix_timestamp(transaction.expires_at)
                .map_err(|_| ServiceError::InvalidRequest)?,
        )?,
        same_site: "Lax",
        http_only: true,
        secure: !state.config.allow_insecure_oidc,
        path: "/auth/step-up/callback",
        domain_mode: "HOST_ONLY",
    })
}

pub async fn consume_step_up_callback(
    state: &AppState,
    request: dto::ConsumeStepUpCallbackRequest,
) -> Result<dto::ConsumeStepUpCallbackResponse, ServiceError> {
    ensure_callback_cookie(&request.transaction_cookie_value, &request.state)?;
    let session = bound_session(state, &request.opaque_session_token, &request.context).await?;
    let claimed = claim_oidc_transaction(&state.pool, &sha256_hex(request.state.as_bytes()))
        .await
        .map_err(|_| ServiceError::Persistence)?
        .ok_or(ServiceError::Conflict)?;
    validate_step_up_binding(
        &claimed,
        session.session_id,
        request.issuer.as_deref(),
        &state.config.oidc_issuer_url,
    )?;
    let identity = exchange_identity(state, &claimed, &request.code).await?;
    let user = active_user_by_subject(&state.pool, &identity.subject)
        .await
        .map_err(|_| ServiceError::Persistence)?
        .ok_or(ServiceError::SessionNotActive)?;
    ensure_step_up_user(user.0, session.user_id)?;
    let (action_digest, idempotency_hash) = step_up_context(&claimed)?;
    let authorization_token = random_token()?;
    let csrf_token = random_token()?;
    let expires_at = OffsetDateTime::now_utc() + Duration::minutes(5);
    let token_hash = sha256_hex(request.opaque_session_token.as_bytes());
    let mut transaction = state
        .pool
        .begin()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    set_step_up_time(
        &mut transaction,
        session.session_id,
        OffsetDateTime::now_utc(),
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    if !rotate_csrf_for_session(
        &mut transaction,
        &token_hash,
        &sha256_hex(csrf_token.as_bytes()),
    )
    .await
    .map_err(|_| ServiceError::Persistence)?
    {
        return Err(ServiceError::SessionNotActive);
    }
    let authorization_id: uuid::Uuid =
        sqlx::query_scalar("SELECT ops.create_step_up_authorization($1,$2,$3,$4,$5)")
            .bind(session.session_id)
            .bind(&action_digest)
            .bind(&idempotency_hash)
            .bind(sha256_hex(authorization_token.as_bytes()))
            .bind(expires_at)
            .fetch_one(&mut *transaction)
            .await
            .map_err(|_| ServiceError::Persistence)?;
    transaction
        .commit()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    Ok(dto::ConsumeStepUpCallbackResponse {
        step_up_authorization_id: authorization_id,
        step_up_authorization_token: authorization_token,
        action_digest,
        idempotency_key_sha256: idempotency_hash,
        return_to: claimed.safe_return_to,
        expires_at: timestamp(expires_at)?,
        max_assertion_issues: 3,
        csrf_token,
        authorization_cookie_path: "/internal",
        authorization_cookie_domain_mode: "HOST_ONLY",
        authorization_cookie_same_site: "Strict",
    })
}

fn ensure_step_up_user(
    user_id: uuid::Uuid,
    session_user_id: uuid::Uuid,
) -> Result<(), ServiceError> {
    (user_id == session_user_id)
        .then_some(())
        .ok_or(ServiceError::CallbackBinding)
}

fn validate_step_up_binding(
    claimed: &gurine_persistence_postgres::identity::ClaimedOidcTransaction,
    session_id: uuid::Uuid,
    issuer: Option<&str>,
    expected_issuer: &str,
) -> Result<(), ServiceError> {
    if claimed.kind != TransactionKind::StepUp
        || claimed.session_id != Some(session_id)
        || claimed.expires_at <= OffsetDateTime::now_utc()
        || issuer.is_some_and(|value| value != expected_issuer)
    {
        return Err(ServiceError::CallbackBinding);
    }
    Ok(())
}

fn step_up_context(
    claimed: &gurine_persistence_postgres::identity::ClaimedOidcTransaction,
) -> Result<(String, String), ServiceError> {
    Ok((
        claimed
            .action_digest
            .clone()
            .ok_or(ServiceError::CallbackBinding)?,
        claimed
            .idempotency_key_sha256
            .clone()
            .ok_or(ServiceError::CallbackBinding)?,
    ))
}

fn provider_config<'a>(
    state: &'a AppState,
    callback_uri: &'a str,
    acr_values: Option<&'a str>,
) -> ProviderConfig<'a> {
    ProviderConfig {
        issuer: &state.config.oidc_issuer_url,
        authorization_endpoint: state.oidc_provider.authorization_endpoint().as_str(),
        client_id: &state.config.oidc_client_id,
        redirect_uri: callback_uri,
        scopes: &state.config.oidc_scopes,
        acr_values,
        allow_insecure_test_issuer: state.config.allow_insecure_oidc,
    }
}
