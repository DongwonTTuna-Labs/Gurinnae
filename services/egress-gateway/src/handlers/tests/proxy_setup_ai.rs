use std::collections::{BTreeMap, BTreeSet};

use actix_web::{http::Method, test::TestRequest};

use super::*;
use crate::config::Config;

fn state(environment: &str) -> GatewayState {
    GatewayState {
        config: Config {
            bind: "127.0.0.1:0".to_owned(),
            environment: environment.to_owned(),
            oidc_issuer_host: "issuer.example".to_owned(),
            source_hosts: BTreeSet::new(),
            source_host_bindings: BTreeMap::new(),
            public_research_hosts: BTreeSet::new(),
            ai_hosts: BTreeSet::from([
                "relay-ai.dongwontuna.net".to_owned(),
                "api.openai.com".to_owned(),
                "api.anthropic.com".to_owned(),
                "generativelanguage.googleapis.com".to_owned(),
            ]),
            challenge_hosts: BTreeSet::new(),
            communication_hosts: BTreeSet::new(),
            object_store: None,
            smtp_url: None,
            data_go_kr_service_key: None,
            open_dart_api_key: None,
            brave_search_api_key: None,
            ai_relay_host: "relay-ai.dongwontuna.net".to_owned(),
            ai_relay_api_key: Some("relay-token".to_owned()),
            openai_api_key: Some("openai-token".to_owned()),
            anthropic_api_key: Some("anthropic-token".to_owned()),
            google_api_key: Some("google-token".to_owned()),
            database_url: None,
        },
        object_store: None,
        smtp: None,
        database: None,
    }
}

fn request(provider: &str) -> HttpRequest {
    TestRequest::default()
        .insert_header(("x-gurine-ai-provider", provider))
        .to_http_request()
}

fn request_with_method(provider: &str, method: Method) -> HttpRequest {
    TestRequest::default()
        .method(method)
        .insert_header(("x-gurine-ai-provider", provider))
        .to_http_request()
}

fn assert_bearer(credential: Option<Credential<'_>>, expected: &str) {
    match credential {
        Some(Credential::Bearer(value)) => assert_eq!(value, expected),
        Some(Credential::Header(_, _)) | None => panic!("expected bearer credential"),
    }
}

#[test]
fn relay_uses_the_single_bearer_credential() {
    let state = state("production");
    let credential = bind_ai_credential(&request("relay"), &state, "relay-ai.dongwontuna.net")
        .expect("relay credential must bind");

    assert_bearer(credential, "relay-token");
}

#[test]
fn relay_rejects_a_host_mismatch_in_production() {
    let state = state("production");
    let result = bind_ai_credential(&request("relay"), &state, "api.openai.com");

    assert!(matches!(result, Err("EGRESS_AI_HOST_MISMATCH")));
}

#[test]
fn relay_rejects_a_host_mismatch_in_development() {
    let state = state("development");
    let result = bind_ai_credential(&request("relay"), &state, "localhost");

    assert!(matches!(result, Err("EGRESS_AI_HOST_MISMATCH")));
}

#[test]
fn relay_mock_host_requires_an_explicit_host_override() {
    let mut state = state("test");
    state.config.ai_relay_host = "localhost".to_owned();

    let credential = bind_ai_credential(&request("relay"), &state, "localhost")
        .expect("explicit relay mock host must bind");

    assert_bearer(credential, "relay-token");
}

#[test]
fn relay_fails_closed_without_its_api_key() {
    let mut state = state("production");
    state.config.ai_relay_api_key = None;

    let result = bind_ai_credential(&request("relay"), &state, "relay-ai.dongwontuna.net");

    assert!(matches!(result, Err("EGRESS_CREDENTIAL_NOT_CONFIGURED")));
}

#[test]
fn legacy_provider_credentials_are_preserved() {
    let state = state("production");

    assert_bearer(
        bind_ai_credential(&request("openai"), &state, "api.openai.com")
            .expect("OpenAI credential must bind"),
        "openai-token",
    );
    assert!(matches!(
        bind_ai_credential(&request("anthropic"), &state, "api.anthropic.com"),
        Ok(Some(Credential::Header("x-api-key", "anthropic-token")))
    ));
    assert!(matches!(
        bind_ai_credential(
            &request("google"),
            &state,
            "generativelanguage.googleapis.com"
        ),
        Ok(Some(Credential::Header("x-goog-api-key", "google-token")))
    ));
}

#[test]
fn legacy_provider_development_mock_host_behavior_is_preserved() {
    let state = state("development");
    let credential = bind_ai_credential(&request("openai"), &state, "localhost")
        .expect("legacy development mock host must bind");

    assert_bearer(credential, "openai-token");
}

#[test]
fn relay_model_get_redirect_cannot_change_the_allowed_path() {
    let request = request_with_method("relay", Method::GET);
    let models =
        Url::parse("https://relay-ai.dongwontuna.net/v1/models").expect("test URL must parse");
    let other_path = Url::parse("https://relay-ai.dongwontuna.net/internal/models")
        .expect("test URL must parse");

    assert!(redirect_method_allowed(Channel::Ai, &request, &models));
    assert!(!redirect_method_allowed(Channel::Ai, &request, &other_path));
}

#[test]
fn relay_chat_redirect_cannot_change_the_allowed_path() {
    let request = request_with_method("relay", Method::POST);
    let chat = Url::parse("https://relay-ai.dongwontuna.net/v1/chat/completions")
        .expect("test URL must parse");
    let other_path =
        Url::parse("https://relay-ai.dongwontuna.net/v1/responses").expect("test URL must parse");

    assert!(redirect_method_allowed(Channel::Ai, &request, &chat));
    assert!(!redirect_method_allowed(Channel::Ai, &request, &other_path));
}

#[test]
fn legacy_ai_post_redirect_behavior_is_preserved() {
    let request = request_with_method("openai", Method::POST);
    let redirected =
        Url::parse("https://api.openai.com/v1/responses").expect("test URL must parse");

    assert!(redirect_method_allowed(Channel::Ai, &request, &redirected));
}
