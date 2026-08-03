use gurine_auth::{assertion::canonical::sha256_hex, oidc::safe_return_target};
use gurine_persistence_postgres::identity::revoke_session_with_audit;
use time::{Duration, OffsetDateTime};
use url::Url;

use crate::{dto, state::AppState};

use super::common::{ServiceError, actor, bound_session, timestamp};

pub async fn resolve_session(
    state: &AppState,
    request: dto::ResolveSessionRequest,
) -> Result<dto::ResolveSessionResponse, ServiceError> {
    let session = bound_session(state, &request.opaque_session_token, &request.context).await?;
    Ok(dto::ResolveSessionResponse {
        actor: actor(&session),
        session_expires_at: timestamp(session.expires_at)?,
        step_up_at: session.step_up_at.map(timestamp).transpose()?,
        csrf_rotated_at: timestamp(session.csrf_rotated_at)?,
        csrf_token_returned: false,
    })
}

pub async fn revoke_session(
    state: &AppState,
    request: dto::RevokeSessionRequest,
) -> Result<dto::RevokeSessionResponse, ServiceError> {
    if request.reason.trim().is_empty() || request.reason.len() > 500 {
        return Err(ServiceError::InvalidRequest);
    }
    let session = bound_session(state, &request.opaque_session_token, &request.context).await?;
    let now = OffsetDateTime::now_utc();
    let audit_event_id = revoke_session_with_audit(
        &state.pool,
        &session,
        &sha256_hex(request.opaque_session_token.as_bytes()),
        &request.reason,
        request.context.request_id,
    )
    .await
    .map_err(|_| ServiceError::Persistence)?
    .ok_or(ServiceError::Conflict)?;
    Ok(dto::RevokeSessionResponse {
        revoked: true,
        revoked_at: timestamp(now)?,
        audit_event_id,
    })
}

pub async fn security_management_redirect(
    state: &AppState,
    request: dto::SecurityManagementRedirectRequest,
) -> Result<dto::SecurityManagementRedirectResponse, ServiceError> {
    let _session = bound_session(state, &request.opaque_session_token, &request.context).await?;
    let return_to = safe_return_target(Some(&request.return_to))?;
    let mut redirect =
        Url::parse(&state.config.oidc_issuer_url).map_err(|_| ServiceError::OidcValidation)?;
    redirect.set_path("/account/security");
    redirect.set_query(None);
    redirect
        .query_pairs_mut()
        .append_pair("return_to", &return_to);
    Ok(dto::SecurityManagementRedirectResponse {
        redirect_url: redirect.to_string(),
        expires_at: timestamp(OffsetDateTime::now_utc() + Duration::minutes(5))?,
    })
}
