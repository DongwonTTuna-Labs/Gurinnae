use gurine_auth::oidc::ActionAuthorizationContext;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RequestContext {
    pub ip_hash: String,
    pub user_agent_hash: String,
    pub request_id: Uuid,
}

impl RequestContext {
    pub fn valid(&self) -> bool {
        is_hash(&self.ip_hash) && is_hash(&self.user_agent_hash)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CreateLoginTransactionRequest {
    pub return_to: String,
    pub callback_uri: String,
    pub context: RequestContext,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateLoginTransactionResponse {
    pub transaction_cookie_value: String,
    pub authorization_url: String,
    pub expires_at: String,
    pub same_site: &'static str,
    pub http_only: bool,
    pub secure: bool,
    pub path: &'static str,
    pub domain_mode: &'static str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ConsumeLoginCallbackRequest {
    pub transaction_cookie_value: String,
    pub code: String,
    pub state: String,
    pub issuer: Option<String>,
    pub context: RequestContext,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActorIdentity {
    pub user_id: Uuid,
    pub email: String,
    pub display_name: String,
    pub role_codes: Vec<String>,
    pub capabilities: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConsumeLoginCallbackResponse {
    pub opaque_session_token: String,
    pub csrf_token: String,
    pub return_to: String,
    pub expires_at: String,
    pub actor: ActorIdentity,
    pub session_cookie_path: &'static str,
    pub session_cookie_domain_mode: &'static str,
    pub session_cookie_same_site: &'static str,
    pub csrf_storage: &'static str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CreateStepUpTransactionRequest {
    pub opaque_session_token: String,
    pub csrf_token: String,
    pub return_to: String,
    pub callback_uri: String,
    pub context: RequestContext,
    pub action_context: ActionAuthorizationContext,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateStepUpTransactionResponse {
    pub transaction_cookie_value: String,
    pub authorization_url: String,
    pub expires_at: String,
    pub same_site: &'static str,
    pub http_only: bool,
    pub secure: bool,
    pub path: &'static str,
    pub domain_mode: &'static str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ConsumeStepUpCallbackRequest {
    pub opaque_session_token: String,
    pub transaction_cookie_value: String,
    pub code: String,
    pub state: String,
    pub issuer: Option<String>,
    pub context: RequestContext,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConsumeStepUpCallbackResponse {
    pub step_up_authorization_id: Uuid,
    pub step_up_authorization_token: String,
    pub action_digest: String,
    pub idempotency_key_sha256: String,
    pub return_to: String,
    pub expires_at: String,
    pub max_assertion_issues: i32,
    pub csrf_token: String,
    pub authorization_cookie_path: &'static str,
    pub authorization_cookie_domain_mode: &'static str,
    pub authorization_cookie_same_site: &'static str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ResolveSessionRequest {
    pub opaque_session_token: String,
    pub context: RequestContext,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveSessionResponse {
    pub actor: ActorIdentity,
    pub session_expires_at: String,
    pub step_up_at: Option<String>,
    pub csrf_rotated_at: String,
    pub csrf_token_returned: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RevokeSessionRequest {
    pub opaque_session_token: String,
    pub reason: String,
    pub context: RequestContext,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RevokeSessionResponse {
    pub revoked: bool,
    pub revoked_at: String,
    pub audit_event_id: Uuid,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecurityManagementRedirectRequest {
    pub opaque_session_token: String,
    pub return_to: String,
    pub context: RequestContext,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SecurityManagementRedirectResponse {
    pub redirect_url: String,
    pub expires_at: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct DownstreamRequestBinding {
    pub method: String,
    pub normalized_path: String,
    pub query_sha256: String,
    pub body_sha256: String,
    pub content_type: String,
    pub request_digest: String,
    pub idempotency_key_sha256: Option<String>,
}

impl DownstreamRequestBinding {
    pub fn valid(&self) -> bool {
        matches!(
            self.method.as_str(),
            "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
        ) && self.normalized_path.starts_with("/v1/internal/")
            && !self.normalized_path.contains(['?', '#'])
            && is_hash(&self.query_sha256)
            && is_hash(&self.body_sha256)
            && is_hash(&self.request_digest)
            && self.idempotency_key_sha256.as_deref().is_none_or(is_hash)
            && matches!(self.content_type.as_str(), "" | "application/json")
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct IssueActorAssertionRequest {
    pub opaque_session_token: String,
    pub downstream_request: DownstreamRequestBinding,
    pub operation_id: String,
    pub required_capability: String,
    pub action_context: Option<ActionAuthorizationContext>,
    pub action_digest: Option<String>,
    pub step_up_authorization_token: Option<String>,
    pub context: RequestContext,
    pub required_assurance_level: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueActorAssertionResponse {
    pub actor: ActorIdentity,
    pub actor_assertion: String,
    pub assertion_expires_at: String,
    pub step_up_authorization_id: Option<Uuid>,
    pub remaining_assertion_issues: Option<i32>,
    pub assurance_level: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CloseStepUpAuthorizationRequest {
    pub opaque_session_token: String,
    pub step_up_authorization_token: String,
    pub action_digest: String,
    pub idempotency_key_sha256: String,
    pub context: RequestContext,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CloseStepUpAuthorizationResponse {
    pub closed: bool,
    pub closed_at: String,
}

pub fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
