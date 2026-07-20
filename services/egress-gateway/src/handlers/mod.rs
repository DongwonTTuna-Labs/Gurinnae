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
    let endpoint = match endpoint.parse() {
        Ok(value) => value,
        Err(_) => return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503),
    };
    let adapter = match Adapter::new(channel, endpoint, credential.token().to_owned()) {
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
        .and_then(|value| value.parse().ok())
    else {
        return problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 503);
    };
    let credential = match resolve_from_environment(channel_name) {
        Ok(resolved) => resolved,
        Err(_) => return problem("COMMUNICATION_CREDENTIAL_RESOLUTION_FAILED", 503),
    };
    let adapter = match Adapter::new(channel, endpoint, credential.token().to_owned()) {
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
    redirect_chain: &str,
    state: &GatewayState,
) -> HttpResponse {
    include!("proxy_response_body.rs")
}
