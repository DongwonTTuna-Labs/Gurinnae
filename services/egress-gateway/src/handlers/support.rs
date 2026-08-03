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

pub(super) fn outbound_header_allowed(channel: Channel, name: &str) -> bool {
    if matches!(channel, Channel::Ai) {
        return matches!(
            name.to_ascii_lowercase().as_str(),
            "content-type" | "accept"
        );
    }
    !hop_or_internal(name) && !caller_credential_header(channel, name)
}

pub(super) fn allowed_method(
    channel: Channel,
    method: &str,
    ai_provider: Option<&str>,
    target: &str,
) -> bool {
    match channel {
        Channel::Oidc => matches!(method, "GET" | "POST"),
        Channel::Source => method == "GET",
        Channel::Ai => match ai_provider {
            Some(provider) if provider.eq_ignore_ascii_case("relay") => url::Url::parse(target)
                .is_ok_and(|url| {
                    matches!(
                        (method, url.path()),
                        ("GET", "/v1/models") | ("POST", "/v1/chat/completions")
                    ) && url.query().is_none()
                        && url.fragment().is_none()
                }),
            _ => method == "POST",
        },
        Channel::Challenge => method == "POST",
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
            | "x-gurine-source-fetch-request-sha256"
            | "x-gurine-source-fetch-max-bytes"
            | "x-gurine-source-fetch-expected-media-types"
            | "x-gurine-allow-redirects"
            | "x-gurine-idempotency-key"
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_model_catalog_get_is_limited_to_the_exact_path() {
        assert!(allowed_method(
            Channel::Ai,
            "GET",
            Some("relay"),
            "https://relay-ai.dongwontuna.net/v1/models"
        ));
        assert!(!allowed_method(
            Channel::Ai,
            "GET",
            Some("openai"),
            "https://relay-ai.dongwontuna.net/v1/models"
        ));
        assert!(!allowed_method(
            Channel::Ai,
            "GET",
            Some("relay"),
            "https://relay-ai.dongwontuna.net/v1/models/"
        ));
        assert!(!allowed_method(
            Channel::Ai,
            "GET",
            Some("relay"),
            "https://relay-ai.dongwontuna.net/v1/models/latest"
        ));
        assert!(!allowed_method(
            Channel::Ai,
            "GET",
            Some("relay"),
            "https://relay-ai.dongwontuna.net/v1/models?limit=1"
        ));
        assert!(!allowed_method(
            Channel::Ai,
            "GET",
            Some("relay"),
            "https://relay-ai.dongwontuna.net/v1/models#catalog"
        ));
        assert!(!allowed_method(
            Channel::Ai,
            "GET",
            Some("relay"),
            "not-a-url"
        ));
    }

    #[test]
    fn relay_post_is_exact_and_legacy_ai_post_policy_is_preserved() {
        assert!(allowed_method(
            Channel::Ai,
            "POST",
            Some("relay"),
            "https://relay-ai.dongwontuna.net/v1/chat/completions"
        ));
        for target in [
            "https://relay-ai.dongwontuna.net/v1/chat/completions/",
            "https://relay-ai.dongwontuna.net/v1/responses",
            "https://relay-ai.dongwontuna.net/v1/chat/completions?stream=true",
            "https://relay-ai.dongwontuna.net/v1/chat/completions#result",
        ] {
            assert!(!allowed_method(Channel::Ai, "POST", Some("relay"), target));
        }
        for provider in ["openai", "anthropic", "google"] {
            assert!(allowed_method(
                Channel::Ai,
                "POST",
                Some(provider),
                "https://provider.example/v1/chat/completions"
            ));
        }
        assert!(!allowed_method(
            Channel::Ai,
            "DELETE",
            Some("relay"),
            "https://relay-ai.dongwontuna.net/v1/models"
        ));
    }

    #[test]
    fn relay_model_catalog_caller_remains_analysis_worker_only() {
        assert!(caller_allowed(Channel::Ai, Some("analysis-worker")));
        assert!(!caller_allowed(Channel::Ai, Some("scheduler")));
        assert!(!caller_allowed(Channel::Ai, None));
    }

    #[test]
    fn ai_outbound_headers_are_closed_to_media_negotiation() {
        assert!(outbound_header_allowed(Channel::Ai, "content-type"));
        assert!(outbound_header_allowed(Channel::Ai, "Accept"));
        for name in [
            "authorization",
            "proxy-authorization",
            "cookie",
            "x-auth-token",
            "x-api-key",
            "x-goog-api-key",
            "x-random-header",
            "x-gurine-ai-model-id",
            "traceparent",
        ] {
            assert!(!outbound_header_allowed(Channel::Ai, name), "{name}");
        }
    }

    #[test]
    fn source_header_policy_strips_transport_and_caller_credentials() {
        assert!(outbound_header_allowed(Channel::Source, "accept"));
        assert!(!outbound_header_allowed(Channel::Source, "authorization"));
        for header in [
            "x-gurine-egress-target",
            "x-gurine-source-id",
            "x-gurine-source-fetch-request-sha256",
            "x-gurine-source-fetch-max-bytes",
            "x-gurine-source-fetch-expected-media-types",
            "x-gurine-allow-redirects",
            "x-gurine-idempotency-key",
        ] {
            assert!(
                !outbound_header_allowed(Channel::Source, header),
                "{header}"
            );
        }
    }
}
