use std::net::{IpAddr, SocketAddr};

use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use gurine_email::port::EmailMessage;
use reqwest::redirect::Policy;
use serde::Deserialize;
use tokio::net::lookup_host;
use url::Url;

use crate::state::GatewayState;

const OIDC_LIMIT: usize = 1_048_576;
const AI_LIMIT: usize = 10_485_760;
const SOURCE_LIMIT: usize = 52_428_800;
const OBJECT_LIMIT: usize = 52_428_800;

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

async fn proxy(
    channel: Channel,
    request: HttpRequest,
    body: web::Bytes,
    state: &GatewayState,
) -> HttpResponse {
    if caller(&request) != Some(expected_caller(channel)) {
        return problem("EGRESS_CALLER_DENIED", 403);
    }
    let Some(target) = header(&request, "x-gurine-egress-target") else {
        return problem("EGRESS_TARGET_REQUIRED", 400);
    };
    if !allowed_method(channel, request.method().as_str()) {
        return problem("EGRESS_METHOD_DENIED", 405);
    }
    let mut target = match validate_target(channel, target, state).await {
        Ok(value) => value,
        Err(code) => return problem(code, 403),
    };
    let credential = match bind_credential(channel, &request, &mut target, state) {
        Ok(value) => value,
        Err(code) => return problem(code, credential_error_status(code)),
    };
    let client = match pinned_client(&target, state).await {
        Ok(value) => value,
        Err(code) => return problem(code, 502),
    };
    let method = match reqwest::Method::from_bytes(request.method().as_str().as_bytes()) {
        Ok(value) => value,
        Err(_) => return problem("EGRESS_METHOD_DENIED", 405),
    };
    let mut outbound = client.request(method, target);
    for (name, value) in request.headers() {
        if !hop_or_internal(name.as_str()) && !caller_credential_header(channel, name.as_str()) {
            outbound = outbound.header(name.as_str(), value.as_bytes());
        }
    }
    outbound = match credential {
        Some(Credential::Bearer(value)) => outbound.bearer_auth(value),
        Some(Credential::Header(name, value)) => outbound.header(name, value),
        None => outbound,
    };
    let response = match outbound.body(body.to_vec()).send().await {
        Ok(value) => value,
        Err(_) => return problem("EGRESS_UPSTREAM_UNAVAILABLE", 502),
    };
    if response.status().is_redirection() {
        return problem("EGRESS_REDIRECT_DENIED", 502);
    }
    proxy_response(response, response_limit(channel)).await
}

fn credential_error_status(code: &str) -> u16 {
    match code {
        "EGRESS_SOURCE_ID_REQUIRED" | "EGRESS_AI_PROVIDER_REQUIRED" => 400,
        "EGRESS_CREDENTIAL_NOT_CONFIGURED" => 503,
        _ => 403,
    }
}

enum Credential<'a> {
    Bearer(&'a str),
    Header(&'static str, &'a str),
}

fn bind_credential<'a>(
    channel: Channel,
    request: &HttpRequest,
    target: &mut Url,
    state: &'a GatewayState,
) -> Result<Option<Credential<'a>>, &'static str> {
    let host = target.host_str().ok_or("EGRESS_TARGET_INVALID")?;
    match channel {
        Channel::Source => {
            let source_id =
                header(request, "x-gurine-source-id").ok_or("EGRESS_SOURCE_ID_REQUIRED")?;
            let expected_host = state
                .config
                .source_host_bindings
                .get(source_id)
                .ok_or("EGRESS_SOURCE_ID_DENIED")?;
            if !state.config.development() && !host.eq_ignore_ascii_case(expected_host) {
                return Err("EGRESS_SOURCE_HOST_MISMATCH");
            }
            match source_id {
                "koneps-contracts" | "koneps-notices" | "local-finance" => {
                    let secret = state
                        .config
                        .data_go_kr_service_key
                        .as_deref()
                        .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED")?;
                    replace_query_secret(target, &["serviceKey"], "serviceKey", secret);
                }
                "open-dart" => {
                    let secret = state
                        .config
                        .open_dart_api_key
                        .as_deref()
                        .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED")?;
                    replace_query_secret(target, &["crtfc_key"], "crtfc_key", secret);
                }
                "alio" | "audit-results" => {}
                _ => return Err("EGRESS_SOURCE_ID_DENIED"),
            }
            Ok(None)
        }
        Channel::Ai => {
            let provider = header(request, "x-gurine-ai-provider")
                .ok_or("EGRESS_AI_PROVIDER_REQUIRED")?
                .to_ascii_lowercase();
            let expected_host = match provider.as_str() {
                "openai" => "api.openai.com",
                "anthropic" => "api.anthropic.com",
                "google" => "generativelanguage.googleapis.com",
                _ => return Err("EGRESS_AI_PROVIDER_DENIED"),
            };
            if !state.config.development() && !host.eq_ignore_ascii_case(expected_host) {
                return Err("EGRESS_AI_HOST_MISMATCH");
            }
            match provider.as_str() {
                "openai" => state
                    .config
                    .openai_api_key
                    .as_deref()
                    .map(Credential::Bearer)
                    .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED"),
                "anthropic" => state
                    .config
                    .anthropic_api_key
                    .as_deref()
                    .map(|value| Credential::Header("x-api-key", value))
                    .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED"),
                "google" => state
                    .config
                    .google_api_key
                    .as_deref()
                    .map(|value| Credential::Header("x-goog-api-key", value))
                    .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED"),
                _ => Err("EGRESS_AI_PROVIDER_DENIED"),
            }
            .map(Some)
        }
        Channel::Oidc | Channel::Challenge => Ok(None),
    }
}

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

fn caller_credential_header(channel: Channel, name: &str) -> bool {
    matches!(channel, Channel::Source | Channel::Ai)
        && matches!(
            name.to_ascii_lowercase().as_str(),
            "authorization" | "proxy-authorization" | "x-api-key" | "x-goog-api-key"
        )
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
    let Some(sender) = state.smtp.as_ref() else {
        return problem("SMTP_NOT_CONFIGURED", 503);
    };
    let payload = payload.into_inner();
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
        .timeout(std::time::Duration::from_secs(60));
    for address in addresses {
        builder = builder.resolve(host, address);
    }
    builder.build().map_err(|_| "EGRESS_CLIENT_FAILED")
}

async fn proxy_response(mut response: reqwest::Response, limit: usize) -> HttpResponse {
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return problem("EGRESS_RESPONSE_TOO_LARGE", 502);
    }
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let mut body = Vec::new();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) if body.len() + chunk.len() <= limit => body.extend_from_slice(&chunk),
            Ok(Some(_)) => return problem("EGRESS_RESPONSE_TOO_LARGE", 502),
            Ok(None) => break,
            Err(_) => return problem("EGRESS_UPSTREAM_UNAVAILABLE", 502),
        }
    }
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut output = HttpResponse::build(status);
    for (name, value) in &headers {
        if !hop_or_internal(name.as_str()) && name.as_str() != "set-cookie" {
            let name = actix_web::http::header::HeaderName::try_from(name.as_str());
            let value = actix_web::http::header::HeaderValue::from_bytes(value.as_bytes());
            if let (Ok(name), Ok(value)) = (name, value) {
                output.insert_header((name, value));
            }
        }
    }
    output.body(body)
}

fn expected_caller(channel: Channel) -> &'static str {
    match channel {
        Channel::Oidc => "identity-api",
        Channel::Source => "ingest-worker",
        Channel::Ai => "analysis-worker",
        Channel::Challenge => "submission-api",
    }
}

fn allowed_method(channel: Channel, method: &str) -> bool {
    match channel {
        Channel::Oidc => matches!(method, "GET" | "POST"),
        Channel::Source => method == "GET",
        Channel::Ai | Channel::Challenge => method == "POST",
    }
}

fn response_limit(channel: Channel) -> usize {
    match channel {
        Channel::Oidc | Channel::Challenge => OIDC_LIMIT,
        Channel::Source => SOURCE_LIMIT,
        Channel::Ai => AI_LIMIT,
    }
}

fn caller(request: &HttpRequest) -> Option<&str> {
    header(request, "x-gurine-egress-caller")
}

fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
}

fn hop_or_internal(name: &str) -> bool {
    matches!(
        name,
        "host"
            | "content-length"
            | "connection"
            | "transfer-encoding"
            | "te"
            | "trailer"
            | "upgrade"
            | "proxy-authorization"
            | "proxy-authenticate"
            | "x-gurine-egress-target"
            | "x-gurine-egress-caller"
            | "x-gurine-source-id"
            | "x-gurine-ai-provider"
            | "x-gurine-object-key"
            | "x-gurine-object-sha256"
    )
}

fn prohibited(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(value) => {
            value.is_private()
                || value.is_loopback()
                || value.is_link_local()
                || value.is_multicast()
                || value.is_broadcast()
                || value.is_unspecified()
                || value.octets() == [169, 254, 169, 254]
        }
        IpAddr::V6(value) => {
            value.is_loopback()
                || value.is_multicast()
                || value.is_unspecified()
                || value.is_unique_local()
                || value.is_unicast_link_local()
        }
    }
}

fn problem(code: &str, status: u16) -> HttpResponse {
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status)
        .insert_header(("content-type", "application/problem+json"))
        .json(serde_json::json!({"code":code,"title":code,"status":status.as_u16()}))
}
