use std::time::{Duration, Instant, SystemTime};

use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use base64::{
    Engine as _, engine::general_purpose::STANDARD, engine::general_purpose::URL_SAFE_NO_PAD,
};
use openidconnect::{
    AccessToken, Audience, AuthenticationContextClass, EmptyAdditionalClaims, IssuerUrl, Nonce,
    PrivateSigningKey, StandardClaims, SubjectIdentifier,
    core::{CoreIdToken, CoreIdTokenClaims, CoreJsonWebKeySet, CoreJwsSigningAlgorithm},
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use url::Url;

use crate::runner::{AppState, AuthorizationRecord};

#[derive(Debug, Deserialize)]
pub struct AuthorizationQuery {
    response_type: String,
    client_id: String,
    redirect_uri: String,
    scope: String,
    state: String,
    nonce: String,
    code_challenge: String,
    code_challenge_method: String,
    acr_values: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TokenForm {
    grant_type: String,
    code: String,
    redirect_uri: String,
    code_verifier: String,
    client_id: Option<String>,
    client_secret: Option<String>,
}

pub async fn discovery(state: web::Data<AppState>) -> HttpResponse {
    let issuer = state.config.issuer.as_str().trim_end_matches('/');
    HttpResponse::Ok().json(serde_json::json!({
        "issuer": issuer,
        "authorization_endpoint": format!("{issuer}/authorize"),
        "token_endpoint": format!("{issuer}/token"),
        "jwks_uri": format!("{issuer}/jwks"),
        "response_types_supported": ["code"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["RS256"],
        "scopes_supported": ["openid", "profile", "email"],
        "claims_supported": ["sub", "iss", "aud", "exp", "iat", "auth_time", "nonce", "acr"],
        "grant_types_supported": ["authorization_code"],
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post"]
    }))
}

pub async fn jwks(state: web::Data<AppState>) -> HttpResponse {
    HttpResponse::Ok().json(CoreJsonWebKeySet::new(vec![
        state.signing_key.as_verification_key(),
    ]))
}

pub async fn authorize(
    query: web::Query<AuthorizationQuery>,
    state: web::Data<AppState>,
) -> HttpResponse {
    if !valid_authorization(&query, &state) {
        return oauth_error("invalid_request", 400);
    }
    let code = match random_token() {
        Ok(value) => value,
        Err(()) => return oauth_error("server_error", 500),
    };
    let record = AuthorizationRecord {
        redirect_uri: query.redirect_uri.clone(),
        nonce: query.nonce.clone(),
        code_challenge: query.code_challenge.clone(),
        acr: query.acr_values.clone(),
        expires_at: Instant::now() + Duration::from_secs(300),
    };
    let mut codes = match state.codes.lock() {
        Ok(value) => value,
        Err(_) => return oauth_error("server_error", 500),
    };
    codes.retain(|_, value| value.expires_at > Instant::now());
    codes.insert(code.clone(), record);
    drop(codes);
    let mut redirect = match Url::parse(&query.redirect_uri) {
        Ok(value) => value,
        Err(_) => return oauth_error("invalid_request", 400),
    };
    redirect
        .query_pairs_mut()
        .append_pair("code", &code)
        .append_pair("state", &query.state)
        .append_pair("iss", state.config.issuer.as_str().trim_end_matches('/'));
    HttpResponse::SeeOther()
        .insert_header(("location", redirect.to_string()))
        .finish()
}

pub async fn token(
    request: HttpRequest,
    form: web::Form<TokenForm>,
    state: web::Data<AppState>,
) -> HttpResponse {
    if form.grant_type != "authorization_code" || !valid_client(&request, &form, &state) {
        return oauth_error("invalid_client", 401);
    }
    let record = {
        let mut codes = match state.codes.lock() {
            Ok(value) => value,
            Err(_) => return oauth_error("server_error", 500),
        };
        codes.remove(&form.code)
    };
    let Some(record) = record else {
        return oauth_error("invalid_grant", 400);
    };
    if record.expires_at <= Instant::now()
        || record.redirect_uri != form.redirect_uri
        || !pkce_matches(&form.code_verifier, &record.code_challenge)
    {
        return oauth_error("invalid_grant", 400);
    }
    let access_token = match random_token() {
        Ok(value) => AccessToken::new(value),
        Err(()) => return oauth_error("server_error", 500),
    };
    let now = SystemTime::now();
    let expiration = now + Duration::from_secs(300);
    let claims = CoreIdTokenClaims::new(
        match IssuerUrl::new(
            state
                .config
                .issuer
                .as_str()
                .trim_end_matches('/')
                .to_owned(),
        ) {
            Ok(value) => value,
            Err(_) => return oauth_error("server_error", 500),
        },
        vec![Audience::new(state.config.client_id.clone())],
        expiration.into(),
        now.into(),
        StandardClaims::new(SubjectIdentifier::new("gurine-test-reviewer".to_owned())),
        EmptyAdditionalClaims {},
    )
    .set_nonce(Some(Nonce::new(record.nonce)))
    .set_auth_time(Some(now.into()))
    .set_auth_context_ref(record.acr.map(AuthenticationContextClass::new));
    let id_token = match CoreIdToken::new(
        claims,
        &state.signing_key,
        CoreJwsSigningAlgorithm::RsaSsaPkcs1V15Sha256,
        Some(&access_token),
        None,
    ) {
        Ok(value) => value,
        Err(_) => return oauth_error("server_error", 500),
    };
    HttpResponse::Ok().json(serde_json::json!({
        "access_token": access_token.secret(),
        "token_type": "Bearer",
        "expires_in": 300,
        "id_token": id_token.to_string(),
        "scope": "openid profile email"
    }))
}

fn valid_authorization(query: &AuthorizationQuery, state: &AppState) -> bool {
    query.response_type == "code"
        && query.client_id == state.config.client_id
        && query
            .scope
            .split_whitespace()
            .any(|scope| scope == "openid")
        && query.code_challenge_method == "S256"
        && query.code_challenge.len() == 43
        && !query.state.is_empty()
        && !query.nonce.is_empty()
        && valid_redirect(&query.redirect_uri)
}

fn valid_redirect(candidate: &str) -> bool {
    let Ok(url) = Url::parse(candidate) else {
        return false;
    };
    matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "/auth/callback" | "/auth/step-up/callback")
        && url
            .host_str()
            .is_some_and(|host| matches!(host, "127.0.0.1" | "localhost" | "review-console"))
}

fn valid_client(request: &HttpRequest, form: &TokenForm, state: &AppState) -> bool {
    let body_credentials = form.client_id.as_deref().zip(form.client_secret.as_deref());
    let basic_credentials = request
        .headers()
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Basic "))
        .and_then(|value| STANDARD.decode(value).ok())
        .and_then(|value| String::from_utf8(value).ok())
        .and_then(|value| {
            value
                .split_once(':')
                .map(|(id, secret)| (id.to_owned(), secret.to_owned()))
        });
    let credentials = body_credentials
        .map(|(id, secret)| (id.to_owned(), secret.to_owned()))
        .or(basic_credentials);
    credentials.is_some_and(|(id, secret)| {
        constant_time_equal(&id, &state.config.client_id)
            && constant_time_equal(&secret, &state.config.client_secret)
    })
}

fn pkce_matches(verifier: &str, challenge: &str) -> bool {
    let calculated = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    constant_time_equal(&calculated, challenge)
}

fn constant_time_equal(left: &str, right: &str) -> bool {
    left.len() == right.len() && bool::from(left.as_bytes().ct_eq(right.as_bytes()))
}

fn random_token() -> Result<String, ()> {
    let mut value = [0_u8; 32];
    getrandom::fill(&mut value).map_err(|_| ())?;
    Ok(URL_SAFE_NO_PAD.encode(value))
}

fn oauth_error(code: &str, status: u16) -> HttpResponse {
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status).json(serde_json::json!({"error":code}))
}
