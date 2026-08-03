use std::{
    collections::BTreeMap,
    net::{IpAddr, SocketAddr},
    sync::{Mutex, OnceLock},
};

use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use gurine_email::port::EmailMessage;
use reqwest::redirect::Policy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::Row;
use tokio::net::lookup_host;
use url::Url;

use crate::{
    communication_adapter::{
        Adapter, Channel as ProviderChannel, OutboundMessage, PollRequest as AdapterPollRequest,
    },
    credential_resolver::resolve_from_environment,
    state::GatewayState,
};

pub mod callbacks;
mod callbacks_support;
mod support;

use support::{
    allowed_method, caller, caller_allowed, caller_credential_header, header, hop_or_internal,
    problem, prohibited, response_limit, sha256_hex,
};

const OBJECT_LIMIT: usize = 52_428_800;
const REPLAY_CACHE_LIMIT: usize = 256 * 1024;

#[derive(Clone, Serialize, Deserialize)]
struct CachedReplay {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}
static REPLAY_CACHE: OnceLock<Mutex<BTreeMap<String, CachedReplay>>> = OnceLock::new();

#[derive(Clone, Copy)]
enum Channel {
    Oidc,
    Source,
    Ai,
    Challenge,
}

pub async fn oidc(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    proxy(Channel::Oidc, request, body, &state).await
}

pub async fn source(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    proxy(Channel::Source, request, body, &state).await
}

pub async fn ai(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    proxy(Channel::Ai, request, body, &state).await
}

pub async fn challenge(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    proxy(Channel::Challenge, request, body, &state).await
}
include!("proxy_setup.rs");
fn replace_query_secret(target: &mut Url, names: &[&str], name: &str, value: &str) {
    let retained = target
        .query_pairs()
        .filter(|(key, _)| {
            !names
                .iter()
                .any(|candidate| key.eq_ignore_ascii_case(candidate))
        })
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect::<Vec<_>>();
    target.set_query(None);
    let mut query = target.query_pairs_mut();
    for (key, value) in retained {
        query.append_pair(&key, &value);
    }
    query.append_pair(name, value);
}

pub async fn object_store(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    if !matches!(
        caller(&request),
        Some("submission-api" | "workflow-worker" | "document-extractor" | "analysis-worker")
    ) {
        return problem("EGRESS_CALLER_DENIED", 403);
    }
    let Some(store) = state.object_store.as_ref() else {
        return problem("OBJECT_STORE_NOT_CONFIGURED", 503);
    };
    let Some(key) = header(&request, "x-gurine-object-key") else {
        return problem("OBJECT_KEY_REQUIRED", 400);
    };
    match request.method().as_str() {
        "PUT" => {
            if body.is_empty() || body.len() > OBJECT_LIMIT {
                return problem("OBJECT_PAYLOAD_INVALID", 413);
            }
            let Some(expected) = header(&request, "x-gurine-object-sha256") else {
                return problem("OBJECT_DIGEST_REQUIRED", 400);
            };
            match store.put(key, body.to_vec(), expected).await {
                Ok(stored) => {
                    let mut response = HttpResponse::NoContent();
                    if let Some(etag) = stored.etag {
                        response.insert_header(("etag", etag));
                    }
                    response.finish()
                }
                Err(_) => problem("OBJECT_STORE_WRITE_FAILED", 502),
            }
        }
        "GET" | "HEAD" => {
            let expected = header(&request, "x-gurine-object-sha256");
            match store.get(key, expected).await {
                Ok(bytes) if request.method().as_str() == "HEAD" => HttpResponse::Ok()
                    .insert_header(("content-length", bytes.len().to_string()))
                    .finish(),
                Ok(bytes) => HttpResponse::Ok()
                    .insert_header(("content-type", "application/octet-stream"))
                    .body(bytes),
                Err(_) => problem("OBJECT_STORE_READ_FAILED", 502),
            }
        }
        "DELETE" => match store.delete(key).await {
            Ok(()) => HttpResponse::NoContent().finish(),
            Err(_) => problem("OBJECT_STORE_DELETE_FAILED", 502),
        },
        _ => problem("EGRESS_METHOD_DENIED", 405),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SmtpRequest {
    channel: String,
    from: String,
    to: String,
    subject: String,
    text_body: String,
    html_body: String,
}

pub async fn smtp(
    request: HttpRequest,
    payload: web::Json<SmtpRequest>,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    if caller(&request) != Some("notification-worker") {
        return problem("EGRESS_CALLER_DENIED", 403);
    }
    let payload = payload.into_inner();
    let channel = payload.channel.to_ascii_uppercase();
    // The SMTP adapter is intentionally email-only.  Non-email channels must
    // be dispatched through their registered provider adapter; routing them
    // into SMTP with a marker header is not delivery.
    if channel != "EMAIL" {
        return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503);
    }
    if kill_switch_active(state.get_ref(), "COMMUNICATION", Some(&channel)).await {
        return problem("COMMUNICATION_EGRESS_KILL_SWITCH_ACTIVE", 503);
    }
    let Some(sender) = state.smtp.as_ref() else {
        return problem("SMTP_NOT_CONFIGURED", 503);
    };
    let message = EmailMessage {
        from: payload.from,
        to: payload.to,
        subject: payload.subject,
        text_body: payload.text_body,
        html_body: payload.html_body,
    };
    match sender.send(&message).await {
        Ok(provider_message_id) => HttpResponse::Ok().json(serde_json::json!({
            "status":"DELIVERED",
            "providerMessageId":provider_message_id
        })),
        Err(_) => problem("SMTP_DELIVERY_FAILED", 502),
    }
}

/// Dispatches a non-email communication through a typed provider adapter.
///
/// Provider credentials stay in the egress process.  The worker supplies only
/// the rendered recipient/content and a stable idempotency key.  A missing
/// endpoint or credential is an explicit 503, never an SMTP fallback.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommunicationRequest {
    recipient: String,
    subject: String,
    text_body: String,
    idempotency_key: String,
}

pub async fn communication(
    request: HttpRequest,
    path: web::Path<String>,
    payload: web::Json<CommunicationRequest>,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    if caller(&request) != Some("notification-worker") {
        return problem("EGRESS_CALLER_DENIED", 403);
    }
    let Some(channel) = ProviderChannel::parse(&path.into_inner()) else {
        return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503);
    };
    let channel_name = match channel {
        ProviderChannel::Telegram => "TELEGRAM",
        ProviderChannel::WhatsApp => "WHATSAPP",
        ProviderChannel::Line => "LINE",
        ProviderChannel::Sms => "SMS",
        ProviderChannel::Kakao => "KAKAO",
    };
    if kill_switch_active(state.get_ref(), "COMMUNICATION", Some(channel_name)).await {
        return problem("COMMUNICATION_EGRESS_KILL_SWITCH_ACTIVE", 503);
    }
    if !provider_revision_is_current(&request, channel_name, state.get_ref()).await {
        return problem("COMMUNICATION_PROVIDER_REVISION_INVALID", 503);
    }
    let prefix = format!("COMMUNICATION_{}_", channel_name);
    let Some(endpoint) = std::env::var(format!("{}URL", prefix))
        .ok()
        .filter(|v| !v.trim().is_empty())
    else {
        return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503);
    };
    let credential = match resolve_from_environment(channel_name) {
        Ok(resolved) => resolved,
        Err(_) => return problem("COMMUNICATION_CREDENTIAL_RESOLUTION_FAILED", 503),
    };
    let endpoint = match validate_communication_target(&endpoint, state.get_ref()).await {
        Ok(value) => value,
        Err(code) => return problem(code, 403),
    };
    let client = match pinned_client(&endpoint, state.get_ref()).await {
        Ok(value) => value,
        Err(code) => return problem(code, 403),
    };
    let adapter =
        match Adapter::with_client(channel, endpoint, credential.token().to_owned(), client) {
            Ok(value) => value,
            Err(_) => return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503),
        };
    let payload = payload.into_inner();
    match adapter
        .send(OutboundMessage {
            recipient: &payload.recipient,
            subject: &payload.subject,
            text: &payload.text_body,
            idempotency_key: &payload.idempotency_key,
        })
        .await
    {
        Ok(provider_message_id) => HttpResponse::Ok().json(serde_json::json!({
            "status": "PROVIDER_ACCEPTED",
            "providerMessageId": provider_message_id,
            "adapterId": channel.adapter_id(),
        })),
        Err(_) => problem("CHANNEL_DELIVERY_FAILED", 502),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommunicationPreflightRequest {
    provider_connection_test_id: uuid::Uuid,
}

/// Performs the provider connection test inside the credential-owning egress
/// boundary and commits only a redacted, immutable receipt.  The notification
/// worker never receives a credential, endpoint secret, or raw provider body.
pub async fn communication_preflight(
    request: HttpRequest,
    payload: web::Json<CommunicationPreflightRequest>,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    if caller(&request) != Some("notification-worker") {
        return problem("EGRESS_CALLER_DENIED", 403);
    }
    let Some(pool) = state.database.as_ref() else {
        return problem("COMMUNICATION_PREFLIGHT_DATABASE_REQUIRED", 503);
    };
    let Some(config_id) = header(&request, "x-gurine-provider-config-id")
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
    else {
        return problem("COMMUNICATION_PROVIDER_REVISION_REQUIRED", 400);
    };
    let Some(config_version) = header(&request, "x-gurine-provider-config-version")
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
    else {
        return problem("COMMUNICATION_PROVIDER_REVISION_REQUIRED", 400);
    };
    let Some(configuration_digest) = header(&request, "x-gurine-provider-configuration-digest")
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
    else {
        return problem("COMMUNICATION_PROVIDER_REVISION_REQUIRED", 400);
    };
    let row = match sqlx::query(
        "SELECT channel,adapter_id,credential_secret_reference,webhook_secret_reference, \
                callback_path,kill_switch_code \
           FROM ops.communication_provider_configs \
          WHERE id=$1 AND version=$2 AND configuration_digest=$3 \
            AND operational_state IN ('DISABLED','UNCONFIGURED','PENDING_PROVIDER_APPROVAL')",
    )
    .bind(config_id)
    .bind(config_version)
    .bind(configuration_digest)
    .fetch_optional(pool)
    .await
    {
        Ok(Some(row)) => row,
        Ok(None) => return problem("COMMUNICATION_PROVIDER_REVISION_INVALID", 409),
        Err(_) => return problem("COMMUNICATION_PREFLIGHT_DATABASE_FAILED", 503),
    };
    let channel: String = match row.try_get("channel") {
        Ok(value) => value,
        Err(_) => return problem("COMMUNICATION_PREFLIGHT_DATABASE_FAILED", 503),
    };
    let adapter_id: String = match row.try_get("adapter_id") {
        Ok(value) => value,
        Err(_) => return problem("COMMUNICATION_PREFLIGHT_DATABASE_FAILED", 503),
    };
    let credential_reference: String = match row.try_get("credential_secret_reference") {
        Ok(value) => value,
        Err(_) => return problem("COMMUNICATION_PREFLIGHT_DATABASE_FAILED", 503),
    };
    let webhook_reference: Option<String> = row.try_get("webhook_secret_reference").ok();
    let callback_path: Option<String> = row.try_get("callback_path").ok();
    let kill_switch_code: String = row.try_get("kill_switch_code").unwrap_or_default();
    let channel_name = match channel.as_str() {
        "SMTP_EMAIL" => "EMAIL",
        "TELEGRAM_BOT_API" => "TELEGRAM",
        "META_WHATSAPP_BUSINESS_CLOUD" => "WHATSAPP",
        "LINE_MESSAGING_API" => "LINE",
        "SOLAPI_SMS" => "SMS",
        "SOLAPI_KAKAO_BIZMESSAGE" => "KAKAO",
        "TWILIO_VOICE" => "VOICE",
        "SIGNED_WEBHOOK" => "WEBHOOK",
        _ => return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 422),
    };
    let mut blockers = Vec::new();
    if kill_switch_active(state.get_ref(), "COMMUNICATION", Some(channel_name)).await {
        blockers.push("KILL_SWITCH_ACTIVE");
    }
    let credential_verified =
        if channel_name == "EMAIL" {
            state.smtp.is_some()
                && state.config.smtp_url.as_deref().is_some_and(|value| {
                    secret_reference_matches_value(&credential_reference, value)
                })
        } else {
            std::env::var(format!(
                "COMMUNICATION_{channel_name}_TOKEN_SECRET_REFERENCE"
            ))
            .as_deref()
                == Ok(credential_reference.as_str())
                && resolve_from_environment(channel_name).is_ok()
        };
    if !credential_verified {
        blockers.push("CREDENTIAL_REVISION_UNVERIFIED");
    }
    let callback_or_poll_verified = channel_name == "WEBHOOK"
        || callback_path
            .as_deref()
            .is_some_and(|path| path.starts_with("/private/v1/callbacks/"))
            && webhook_reference.as_deref().is_some_and(|reference| {
                std::env::var(format!(
                    "COMMUNICATION_{channel_name}_WEBHOOK_SECRET_REFERENCE"
                ))
                .as_deref()
                    == Ok(reference)
            });
    if !callback_or_poll_verified {
        blockers.push("CALLBACK_OR_POLL_UNVERIFIED");
    }
    let live_sandbox = if channel_name == "EMAIL" {
        smtp_preflight(state.get_ref()).await
    } else if matches!(channel_name, "VOICE" | "WEBHOOK") {
        false
    } else {
        communication_http_preflight(channel_name, state.get_ref()).await
    };
    if !live_sandbox {
        blockers.push("LIVE_SANDBOX_UNREACHABLE");
    }
    let result = if blockers.is_empty() { "PASS" } else { "FAIL" };
    let checklist = serde_json::json!({
        "adapterId": adapter_id,
        "callbackOrPollVerified": callback_or_poll_verified,
        "credentialRevisionVerified": credential_verified,
        "killSwitchInactive": !blockers.contains(&"KILL_SWITCH_ACTIVE"),
        "killSwitchCodePresent": !kill_switch_code.is_empty(),
        "liveSandbox": live_sandbox,
        "redacted": true,
    });
    let provider_evidence_digest = sha256_hex(
        format!("{config_id}:{config_version}:{configuration_digest}:{result}:{checklist}")
            .as_bytes(),
    );
    let receipt: serde_json::Value = match sqlx::query_scalar(
        "SELECT ops.record_communication_provider_preflight_v1( \
           $1,$2,$3,$4::char(64),$5,$6,$7,$8::char(64))",
    )
    .bind(payload.provider_connection_test_id)
    .bind(config_id)
    .bind(config_version)
    .bind(configuration_digest)
    .bind(result)
    .bind(checklist)
    .bind(serde_json::json!(blockers))
    .bind(provider_evidence_digest)
    .fetch_one(pool)
    .await
    {
        Ok(value) => value,
        Err(_) => return problem("COMMUNICATION_PREFLIGHT_PERSISTENCE_FAILED", 503),
    };
    HttpResponse::Ok().json(receipt)
}

fn secret_reference_matches_value(reference: &str, secret_value: &str) -> bool {
    let digest = sha256_hex(secret_value.as_bytes());
    reference
        .rsplit_once("@v")
        .is_some_and(|(_, version)| version == digest)
}

async fn smtp_preflight(state: &GatewayState) -> bool {
    let Some(url) = state.config.smtp_url.as_deref() else {
        return false;
    };
    let Ok(parsed) = Url::parse(url) else {
        return false;
    };
    let Some(host) = parsed.host_str() else {
        return false;
    };
    let port = parsed
        .port()
        .unwrap_or(if parsed.scheme() == "smtps" { 465 } else { 25 });
    tokio::time::timeout(
        std::time::Duration::from_secs(5),
        tokio::net::TcpStream::connect((host, port)),
    )
    .await
    .is_ok_and(|result| result.is_ok())
}

async fn communication_http_preflight(channel: &str, state: &GatewayState) -> bool {
    let Some(endpoint) = std::env::var(format!("COMMUNICATION_{channel}_URL"))
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        return false;
    };
    let Ok(target) = validate_communication_target(&endpoint, state).await else {
        return false;
    };
    let Ok(client) = pinned_client(&target, state).await else {
        return false;
    };
    client
        .head(target)
        .send()
        .await
        .is_ok_and(|response| response.status().is_success())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommunicationPollRequest {
    provider_message_id: String,
}

/// Executes an authenticated provider-native status poll.  The response is a
/// normalized, digest-bound proof; no raw provider body or credential-bearing
/// headers cross the egress boundary.
pub async fn communication_poll(
    request: HttpRequest,
    path: web::Path<String>,
    payload: web::Json<CommunicationPollRequest>,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    if caller(&request) != Some("notification-worker") {
        return problem("EGRESS_CALLER_DENIED", 403);
    }
    let Some(channel) = ProviderChannel::parse(&path.into_inner()) else {
        return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503);
    };
    let channel_name = match channel {
        ProviderChannel::Telegram => "TELEGRAM",
        ProviderChannel::WhatsApp => "WHATSAPP",
        ProviderChannel::Line => "LINE",
        ProviderChannel::Sms => "SMS",
        ProviderChannel::Kakao => "KAKAO",
    };
    if kill_switch_active(state.get_ref(), "COMMUNICATION", Some(channel_name)).await {
        return problem("COMMUNICATION_EGRESS_KILL_SWITCH_ACTIVE", 503);
    }
    if !provider_revision_is_current(&request, channel_name, state.get_ref()).await {
        return problem("COMMUNICATION_PROVIDER_REVISION_INVALID", 503);
    }
    let prefix = format!("COMMUNICATION_{}_", channel_name);
    let Some(endpoint) = std::env::var(format!("{}URL", prefix))
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503);
    };
    let endpoint = match validate_communication_target(&endpoint, state.get_ref()).await {
        Ok(value) => value,
        Err(code) => return problem(code, 403),
    };
    let credential = match resolve_from_environment(channel_name) {
        Ok(resolved) => resolved,
        Err(_) => return problem("COMMUNICATION_CREDENTIAL_RESOLUTION_FAILED", 503),
    };
    let client = match pinned_client(&endpoint, state.get_ref()).await {
        Ok(value) => value,
        Err(code) => return problem(code, 403),
    };
    let adapter =
        match Adapter::with_client(channel, endpoint, credential.token().to_owned(), client) {
            Ok(value) => value,
            Err(_) => return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503),
        };
    match adapter
        .poll(AdapterPollRequest {
            provider_message_id: &payload.provider_message_id,
        })
        .await
    {
        Ok(receipt) => HttpResponse::Ok().json(serde_json::json!({
            "status": "AUTHENTICATED_PROVIDER_POLL",
            "providerMessageId": receipt.provider_message_id,
            "assertedState": receipt.state,
            "providerEvidenceDigest": receipt.provider_evidence_digest,
            "adapterId": channel.adapter_id(),
        })),
        Err(crate::communication_adapter::AdapterError::PollUnsupported) => {
            problem("CHANNEL_POLL_UNSUPPORTED", 422)
        }
        Err(_) => problem("CHANNEL_POLL_FAILED", 502),
    }
}

pub use callbacks::{
    communication_callback, communication_callback_smtp,
    communication_callback_smtp_with_integration,
};

async fn provider_revision_is_current(
    request: &HttpRequest,
    channel: &str,
    state: &GatewayState,
) -> bool {
    let Some(pool) = state.database.as_ref() else {
        return false;
    };
    let Some(config_id) = header(request, "x-gurine-provider-config-id")
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
    else {
        return false;
    };
    let Some(config_version) = header(request, "x-gurine-provider-config-version")
        .and_then(|value| value.parse::<i64>().ok())
    else {
        return false;
    };
    let Some(config_digest) = header(request, "x-gurine-provider-configuration-digest") else {
        return false;
    };
    let Some(preflight_id) = header(request, "x-gurine-provider-preflight-id")
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
    else {
        return false;
    };
    let Some(preflight_digest) = header(request, "x-gurine-provider-preflight-digest") else {
        return false;
    };
    let Some(secret_reference) =
        std::env::var(format!("COMMUNICATION_{}_TOKEN_SECRET_REFERENCE", channel))
            .ok()
            .filter(|value| !value.trim().is_empty())
    else {
        return false;
    };
    let row = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM ops.communication_provider_configs pc JOIN ops.communication_provider_preflight_receipts pf ON pf.provider_config_id=pc.id AND pf.provider_config_version=pc.version AND pf.configuration_digest=pc.configuration_digest WHERE pc.id=$1 AND pc.version=$2 AND pc.configuration_digest=$3 AND pc.channel = CASE $6 WHEN 'TELEGRAM' THEN 'TELEGRAM_BOT_API' WHEN 'WHATSAPP' THEN 'META_WHATSAPP_BUSINESS_CLOUD' WHEN 'LINE' THEN 'LINE_MESSAGING_API' WHEN 'SMS' THEN 'SOLAPI_SMS' WHEN 'KAKAO' THEN 'SOLAPI_KAKAO_BIZMESSAGE' ELSE '' END AND pc.credential_secret_reference=$7 AND pc.operational_state='ACTIVE' AND pc.activation_effective_at<=clock_timestamp() AND (pc.activation_expires_at IS NULL OR pc.activation_expires_at>clock_timestamp()) AND pf.id=$4 AND pf.receipt_digest=$5 AND pf.result='PASS' AND pf.expires_at>clock_timestamp() AND pf.live_sandbox AND pf.callback_or_poll_verified AND pf.sender_identity_verified AND pf.template_catalog_verified)",
    )
    .bind(config_id).bind(config_version).bind(config_digest).bind(preflight_id).bind(preflight_digest).bind(channel)
    .bind(secret_reference)
    .fetch_one(pool).await;
    row.unwrap_or(false)
}

async fn kill_switch_active(state: &GatewayState, tier: &str, channel: Option<&str>) -> bool {
    let Some(pool) = state.database.as_ref() else {
        // Development/test may run without a database; production config
        // rejects that shape before the server starts.
        return false;
    };
    let active: Result<bool, _> = sqlx::query_scalar(
        "SELECT EXISTS(
           SELECT 1 FROM ops.kill_switches k
           WHERE k.state='ACTIVE'
             AND (k.expires_at IS NULL OR k.expires_at > clock_timestamp())
             AND (
               k.scope='{}'::jsonb
               OR k.code ILIKE ('%' || $1 || '%')
               OR k.scope ? lower($1)
               OR k.scope ? 'all'
               OR ($2::text IS NOT NULL AND k.scope ? lower($2))
               OR ($2::text IS NOT NULL AND k.scope @> jsonb_build_object('channel',$2))
             )
         )",
    )
    .bind(tier)
    .bind(channel)
    .fetch_one(pool)
    .await;
    // A failed read is a fail-closed egress decision.  This prevents an
    // unavailable control database from silently bypassing an incident stop.
    active.unwrap_or(true)
}

async fn validate_target(
    channel: Channel,
    target: &str,
    state: &GatewayState,
) -> Result<Url, &'static str> {
    let url = Url::parse(target).map_err(|_| "EGRESS_TARGET_INVALID")?;
    if url.username() != "" || url.password().is_some() || url.fragment().is_some() {
        return Err("EGRESS_TARGET_INVALID");
    }
    let host = url
        .host_str()
        .ok_or("EGRESS_TARGET_INVALID")?
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if host.parse::<IpAddr>().is_ok() || !allowed_host(channel, &host, state) {
        return Err("EGRESS_HOST_DENIED");
    }
    let scheme_allowed =
        url.scheme() == "https" || (state.config.development() && url.scheme() == "http");
    if !scheme_allowed {
        return Err("EGRESS_SCHEME_DENIED");
    }
    let port = url.port_or_known_default().ok_or("EGRESS_TARGET_INVALID")?;
    let addresses = lookup_host((&*host, port))
        .await
        .map_err(|_| "EGRESS_DNS_FAILED")?
        .collect::<Vec<_>>();
    if addresses.is_empty()
        || addresses
            .iter()
            .any(|address| prohibited(address.ip()) && !development_private_allowed(&host, state))
    {
        return Err("EGRESS_ADDRESS_DENIED");
    }
    Ok(url)
}

/// Communication adapters use a separate HTTP client from the generic proxy,
/// so the endpoint must be subjected to the same closed-host, HTTPS, DNS and
/// private-address policy before it reaches the provider-specific client.
async fn validate_communication_target(
    target: &str,
    state: &GatewayState,
) -> Result<Url, &'static str> {
    let url = Url::parse(target).map_err(|_| "EGRESS_TARGET_INVALID")?;
    if url.username() != "" || url.password().is_some() || url.fragment().is_some() {
        return Err("EGRESS_TARGET_INVALID");
    }
    let host = url
        .host_str()
        .ok_or("EGRESS_TARGET_INVALID")?
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if host.parse::<IpAddr>().is_ok() || !state.config.communication_hosts.contains(&host) {
        return Err("EGRESS_HOST_DENIED");
    }
    let scheme_allowed =
        url.scheme() == "https" || (state.config.development() && url.scheme() == "http");
    if !scheme_allowed {
        return Err("EGRESS_SCHEME_DENIED");
    }
    let port = url.port_or_known_default().ok_or("EGRESS_TARGET_INVALID")?;
    let addresses = lookup_host((&*host, port))
        .await
        .map_err(|_| "EGRESS_DNS_FAILED")?
        .collect::<Vec<_>>();
    if addresses.is_empty() || addresses.iter().any(|address| prohibited(address.ip())) {
        return Err("EGRESS_ADDRESS_DENIED");
    }
    Ok(url)
}

fn allowed_host(channel: Channel, host: &str, state: &GatewayState) -> bool {
    match channel {
        Channel::Oidc => host == state.config.oidc_issuer_host,
        Channel::Source => state.config.source_hosts.contains(host),
        Channel::Ai => state.config.ai_hosts.contains(host),
        Channel::Challenge => state.config.challenge_hosts.contains(host),
    }
}

fn development_private_allowed(host: &str, state: &GatewayState) -> bool {
    state.config.development()
        && (host == "localhost"
            || host == "oidc-test-provider"
            || host == state.config.oidc_issuer_host
            || state.config.source_hosts.contains(host)
            || state.config.ai_hosts.contains(host)
            || state.config.challenge_hosts.contains(host))
}

async fn pinned_client(
    target: &Url,
    state: &GatewayState,
) -> Result<reqwest::Client, &'static str> {
    let host = target.host_str().ok_or("EGRESS_TARGET_INVALID")?;
    let port = target
        .port_or_known_default()
        .ok_or("EGRESS_TARGET_INVALID")?;
    let addresses = lookup_host((host, port))
        .await
        .map_err(|_| "EGRESS_DNS_FAILED")?
        .collect::<Vec<SocketAddr>>();
    if addresses.is_empty()
        || addresses
            .iter()
            .any(|address| prohibited(address.ip()) && !development_private_allowed(host, state))
    {
        return Err("EGRESS_ADDRESS_DENIED");
    }
    let mut builder = reqwest::Client::builder()
        .redirect(Policy::none())
        .no_gzip()
        .no_brotli()
        .no_deflate()
        .connect_timeout(std::time::Duration::from_secs(5))
        .timeout(std::time::Duration::from_secs(15));
    for address in addresses {
        builder = builder.resolve(host, address);
    }
    builder.build().map_err(|_| "EGRESS_CLIENT_FAILED")
}

async fn proxy_response(
    mut response: reqwest::Response,
    limit: usize,
    target: &str,
    idempotency_key: &str,
    request_digest: &str,
    redirect_chain: &str,
    state: &GatewayState,
) -> HttpResponse {
    include!("proxy_response_body.rs")
}
