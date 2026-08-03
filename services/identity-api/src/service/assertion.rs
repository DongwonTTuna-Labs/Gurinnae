use gurine_auth::{
    assertion::{
        actor::{ActorClaims, sign},
        canonical::sha256_hex,
    },
    oidc::ActionAuthorizationContext,
};
use gurine_persistence_postgres::identity::{
    StepUpClaim, claim_step_up_authorization, close_step_up_authorization as close_authorization,
};
use time::{Duration, OffsetDateTime};
use uuid::Uuid;

use crate::{dto, state::AppState};

use super::common::{ServiceError, actor, bound_session, timestamp};

const RECENT_SESSION_SECONDS: i64 = 900;

pub async fn issue_actor_assertion(
    state: &AppState,
    request: dto::IssueActorAssertionRequest,
) -> Result<dto::IssueActorAssertionResponse, ServiceError> {
    validate_issue_request(&request)?;
    let session = bound_session(state, &request.opaque_session_token, &request.context).await?;
    if request.required_capability != "none"
        && !session
            .capabilities
            .iter()
            .any(|capability| capability == &request.required_capability)
    {
        return Err(ServiceError::CapabilityDenied);
    }
    let now = OffsetDateTime::now_utc();
    let step_up = assurance(
        state,
        &session,
        &request,
        now,
        &sha256_hex(request.opaque_session_token.as_bytes()),
    )
    .await?;
    let mut capabilities = session.capabilities.clone();
    capabilities.sort_unstable();
    capabilities.dedup();
    let expires_at = now + Duration::seconds(20);
    let claims = ActorClaims {
        action_digest: request.action_digest.clone(),
        assurance_level: request.required_assurance_level.clone(),
        aud: "control-api".to_owned(),
        auth_time: session.auth_time.unix_timestamp(),
        body_sha256: request.downstream_request.body_sha256.clone(),
        capabilities: capabilities.clone(),
        capability_hash: sha256_hex(capabilities.join("\n").as_bytes()),
        content_type: request.downstream_request.content_type.clone(),
        exp: expires_at.unix_timestamp(),
        iat: now.unix_timestamp(),
        idempotency_key_sha256: request.downstream_request.idempotency_key_sha256.clone(),
        iss: "identity-api".to_owned(),
        jti: Uuid::new_v4().to_string(),
        method: request.downstream_request.method.clone(),
        operation_id: request.operation_id.clone(),
        path: request.downstream_request.normalized_path.clone(),
        query_sha256: request.downstream_request.query_sha256.clone(),
        required_capability: request.required_capability.clone(),
        roles_version: session.roles_version,
        sid: session.session_id.to_string(),
        step_up_at: session.step_up_at.map(OffsetDateTime::unix_timestamp),
        step_up_authorization_id: step_up
            .as_ref()
            .map(|claim| claim.authorization_id.to_string()),
        sub: session.user_id.to_string(),
        typ: "actor".to_owned(),
        v: 1,
    };
    let actor_assertion =
        sign(&claims, &state.actor_assertion_key).map_err(|_| ServiceError::Cryptography)?;
    Ok(dto::IssueActorAssertionResponse {
        actor: actor(&session),
        actor_assertion,
        assertion_expires_at: timestamp(expires_at)?,
        step_up_authorization_id: step_up.as_ref().map(|claim| claim.authorization_id),
        remaining_assertion_issues: step_up.as_ref().map(|claim| claim.remaining_issues),
        assurance_level: request.required_assurance_level,
    })
}

pub async fn close_step_up_authorization(
    state: &AppState,
    request: dto::CloseStepUpAuthorizationRequest,
) -> Result<dto::CloseStepUpAuthorizationResponse, ServiceError> {
    if !dto::is_hash(&request.action_digest)
        || !dto::is_hash(&request.idempotency_key_sha256)
        || request.step_up_authorization_token.len() < 43
    {
        return Err(ServiceError::InvalidRequest);
    }
    let session = bound_session(state, &request.opaque_session_token, &request.context).await?;
    let closed = close_authorization(
        &state.pool,
        &sha256_hex(request.step_up_authorization_token.as_bytes()),
        session.session_id,
        &request.action_digest,
        &request.idempotency_key_sha256,
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    Ok(dto::CloseStepUpAuthorizationResponse {
        closed,
        closed_at: timestamp(OffsetDateTime::now_utc())?,
    })
}

fn validate_issue_request(request: &dto::IssueActorAssertionRequest) -> Result<(), ServiceError> {
    if !request.context.valid()
        || !request.downstream_request.valid()
        || request.operation_id.is_empty()
        || request.required_capability.is_empty()
        || !matches!(
            request.required_assurance_level.as_str(),
            "ACTIVE_SESSION" | "RECENT_SESSION" | "STEP_UP"
        )
    {
        return Err(ServiceError::InvalidRequest);
    }
    let digest = sha256_hex(
        format!(
            "{}\n{}\n{}\n{}\n{}\n{}",
            request.downstream_request.method,
            request.downstream_request.normalized_path,
            request.downstream_request.query_sha256,
            request.downstream_request.body_sha256,
            request.downstream_request.content_type,
            request
                .downstream_request
                .idempotency_key_sha256
                .as_deref()
                .unwrap_or("")
        )
        .as_bytes(),
    );
    if digest != request.downstream_request.request_digest {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

async fn assurance(
    state: &AppState,
    session: &gurine_persistence_postgres::identity::ResolvedSession,
    request: &dto::IssueActorAssertionRequest,
    now: OffsetDateTime,
    _session_token_hash: &str,
) -> Result<Option<StepUpClaim>, ServiceError> {
    match request.required_assurance_level.as_str() {
        "ACTIVE_SESSION" => {
            reject_step_up_fields(request)?;
            Ok(None)
        }
        "RECENT_SESSION" => {
            reject_step_up_fields(request)?;
            let latest = session
                .step_up_at
                .unwrap_or(session.auth_time)
                .max(session.auth_time);
            if now - latest > Duration::seconds(RECENT_SESSION_SECONDS) {
                return Err(ServiceError::AssuranceInsufficient);
            }
            Ok(None)
        }
        "STEP_UP" => claim_step_up(state, session.session_id, request, now)
            .await
            .map(Some),
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn claim_step_up(
    state: &AppState,
    session_id: Uuid,
    request: &dto::IssueActorAssertionRequest,
    now: OffsetDateTime,
) -> Result<StepUpClaim, ServiceError> {
    let context: &ActionAuthorizationContext = request
        .action_context
        .as_ref()
        .ok_or(ServiceError::AssuranceInsufficient)?;
    context.validate()?;
    let digest = context.digest()?;
    let supplied_digest = request
        .action_digest
        .as_deref()
        .ok_or(ServiceError::AssuranceInsufficient)?;
    let authorization_token = request
        .step_up_authorization_token
        .as_deref()
        .ok_or(ServiceError::AssuranceInsufficient)?;
    if digest != supplied_digest
        || context.operation_id != request.operation_id
        || context.business_payload_sha256 != request.downstream_request.body_sha256
        || request.downstream_request.idempotency_key_sha256.as_deref()
            != Some(context.idempotency_key_sha256.as_str())
    {
        return Err(ServiceError::CallbackBinding);
    }
    claim_step_up_authorization(
        &state.pool,
        &sha256_hex(authorization_token.as_bytes()),
        session_id,
        supplied_digest,
        &context.idempotency_key_sha256,
        now,
    )
    .await
    .map_err(|_| ServiceError::AssuranceInsufficient)
}

fn reject_step_up_fields(request: &dto::IssueActorAssertionRequest) -> Result<(), ServiceError> {
    if request.action_context.is_some()
        || request.action_digest.is_some()
        || request.step_up_authorization_token.is_some()
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}
