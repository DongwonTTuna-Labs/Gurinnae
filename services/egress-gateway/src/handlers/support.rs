use actix_web::{HttpRequest, HttpResponse, http::StatusCode};
use sha2::{Digest, Sha256};
use std::net::IpAddr;

use super::Channel;

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub(super) fn expected_caller(channel: Channel) -> &'static str {
    match channel {
        Channel::Oidc => "identity-api",
        Channel::Source => "ingest-worker",
        Channel::Ai => "analysis-worker",
        Channel::Challenge => "submission-api",
    }
}

pub(super) fn caller_allowed(channel: Channel, actual: Option<&str>) -> bool {
    match (channel, actual) {
        (Channel::Source, Some("analysis-worker" | "ingest-worker")) => true,
        (channel, Some(value)) => value == expected_caller(channel),
        _ => false,
    }
}

pub(super) fn caller_credential_header(channel: Channel, name: &str) -> bool {
    matches!(channel, Channel::Source | Channel::Ai)
        && matches!(
            name.to_ascii_lowercase().as_str(),
            "authorization" | "proxy-authorization" | "x-api-key" | "x-goog-api-key"
        )
}

pub(super) fn allowed_method(channel: Channel, method: &str) -> bool {
    match channel {
        Channel::Oidc => matches!(method, "GET" | "POST"),
        Channel::Source => method == "GET",
        Channel::Ai | Channel::Challenge => method == "POST",
    }
}

pub(super) fn response_limit(channel: Channel) -> usize {
    match channel {
        Channel::Oidc | Channel::Challenge => 1_048_576,
        Channel::Source => 26_214_400,
        Channel::Ai => 10_485_760,
    }
}

pub(super) fn caller(request: &HttpRequest) -> Option<&str> {
    header(request, "x-gurine-egress-caller")
}

pub(super) fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
}

pub(super) fn hop_or_internal(name: &str) -> bool {
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

pub(super) fn prohibited(address: IpAddr) -> bool {
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

pub(super) fn problem(code: &str, status: u16) -> HttpResponse {
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status)
        .insert_header(("content-type", "application/problem+json"))
        .json(serde_json::json!({"code":code,"title":code,"status":status.as_u16()}))
}
