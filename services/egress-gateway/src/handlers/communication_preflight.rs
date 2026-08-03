use actix_web::{HttpRequest, HttpResponse, web};
use serde::Deserialize;
use url::Url;

use super::{
    kill_switch_active, pinned_client,
    support::{caller, header, problem, sha256_hex},
    validate_communication_target,
};
use crate::{credential_resolver::resolve_from_environment, state::GatewayState};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommunicationPreflightRequest {
    provider_connection_test_id: uuid::Uuid,
}

struct ProviderRevision {
    config_id: uuid::Uuid,
    config_version: i64,
    configuration_digest: String,
}

struct PreflightConfiguration {
    adapter_id: String,
    credential_reference: String,
    webhook_reference: Option<String>,
    callback_path: Option<String>,
    kill_switch_code: String,
    channel_name: &'static str,
}

struct PreflightEvidence {
    result: &'static str,
    checklist: serde_json::Value,
    blockers: Vec<&'static str>,
    provider_evidence_digest: String,
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
    let revision = match provider_revision(&request) {
        Ok(value) => value,
        Err(response) => return response,
    };
    let configuration = match load_preflight_configuration(pool, &revision).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    let evidence = verify_preflight(&revision, &configuration, state.get_ref()).await;
    let receipt = match persist_preflight_receipt(
        pool,
        payload.provider_connection_test_id,
        &revision,
        evidence,
    )
    .await
    {
        Ok(value) => value,
        Err(response) => return response,
    };
    HttpResponse::Ok().json(receipt)
}

fn provider_revision(request: &HttpRequest) -> Result<ProviderRevision, HttpResponse> {
    let Some(config_id) = header(request, "x-gurine-provider-config-id")
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
    else {
        return Err(problem("COMMUNICATION_PROVIDER_REVISION_REQUIRED", 400));
    };
    let Some(config_version) = header(request, "x-gurine-provider-config-version")
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
    else {
        return Err(problem("COMMUNICATION_PROVIDER_REVISION_REQUIRED", 400));
    };
    let Some(configuration_digest) = header(request, "x-gurine-provider-configuration-digest")
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
    else {
        return Err(problem("COMMUNICATION_PROVIDER_REVISION_REQUIRED", 400));
    };
    Ok(ProviderRevision {
        config_id,
        config_version,
        configuration_digest: configuration_digest.to_owned(),
    })
}

async fn load_preflight_configuration(
    pool: &sqlx::PgPool,
    revision: &ProviderRevision,
) -> Result<PreflightConfiguration, HttpResponse> {
    let row = match sqlx::query!(
        "SELECT channel,adapter_id,credential_secret_reference,webhook_secret_reference, \
                callback_path,kill_switch_code \
           FROM ops.communication_provider_configs \
          WHERE id=$1 AND version=$2 AND configuration_digest=$3 \
            AND operational_state IN ('DISABLED','UNCONFIGURED','PENDING_PROVIDER_APPROVAL')",
        revision.config_id,
        revision.config_version,
        &revision.configuration_digest,
    )
    .fetch_optional(pool)
    .await
    {
        Ok(Some(row)) => row,
        Ok(None) => return Err(problem("COMMUNICATION_PROVIDER_REVISION_INVALID", 409)),
        Err(_) => return Err(problem("COMMUNICATION_PREFLIGHT_DATABASE_FAILED", 503)),
    };
    let channel = row.channel;
    let adapter_id = row.adapter_id;
    let credential_reference = row.credential_secret_reference;
    let webhook_reference = row.webhook_secret_reference;
    let callback_path = row.callback_path;
    let kill_switch_code = row.kill_switch_code;
    let channel_name = match channel.as_str() {
        "SMTP_EMAIL" => "EMAIL",
        "TELEGRAM_BOT_API" => "TELEGRAM",
        "META_WHATSAPP_BUSINESS_CLOUD" => "WHATSAPP",
        "LINE_MESSAGING_API" => "LINE",
        "SOLAPI_SMS" => "SMS",
        "SOLAPI_KAKAO_BIZMESSAGE" => "KAKAO",
        "TWILIO_VOICE" => "VOICE",
        "SIGNED_WEBHOOK" => "WEBHOOK",
        _ => return Err(problem("CHANNEL_ADAPTER_NOT_CONFIGURED", 422)),
    };
    Ok(PreflightConfiguration {
        adapter_id,
        credential_reference,
        webhook_reference,
        callback_path,
        kill_switch_code,
        channel_name,
    })
}

async fn verify_preflight(
    revision: &ProviderRevision,
    configuration: &PreflightConfiguration,
    state: &GatewayState,
) -> PreflightEvidence {
    let mut blockers = Vec::new();
    if kill_switch_active(state, "COMMUNICATION", Some(configuration.channel_name)).await {
        blockers.push("KILL_SWITCH_ACTIVE");
    }
    let credential_verified = if configuration.channel_name == "EMAIL" {
        state.smtp.is_some()
            && state.config.smtp_url.as_deref().is_some_and(|value| {
                secret_reference_matches_value(&configuration.credential_reference, value)
            })
    } else {
        std::env::var(format!(
            "COMMUNICATION_{}_TOKEN_SECRET_REFERENCE",
            configuration.channel_name
        ))
        .as_deref()
            == Ok(configuration.credential_reference.as_str())
            && resolve_from_environment(configuration.channel_name).is_ok()
    };
    if !credential_verified {
        blockers.push("CREDENTIAL_REVISION_UNVERIFIED");
    }
    let callback_or_poll_verified = configuration.channel_name == "WEBHOOK"
        || configuration
            .callback_path
            .as_deref()
            .is_some_and(|path| path.starts_with("/private/v1/callbacks/"))
            && configuration
                .webhook_reference
                .as_deref()
                .is_some_and(|reference| {
                    std::env::var(format!(
                        "COMMUNICATION_{}_WEBHOOK_SECRET_REFERENCE",
                        configuration.channel_name
                    ))
                    .as_deref()
                        == Ok(reference)
                });
    if !callback_or_poll_verified {
        blockers.push("CALLBACK_OR_POLL_UNVERIFIED");
    }
    let live_sandbox = if configuration.channel_name == "EMAIL" {
        smtp_preflight(state).await
    } else if matches!(configuration.channel_name, "VOICE" | "WEBHOOK") {
        false
    } else {
        communication_http_preflight(configuration.channel_name, state).await
    };
    if !live_sandbox {
        blockers.push("LIVE_SANDBOX_UNREACHABLE");
    }
    let result = if blockers.is_empty() { "PASS" } else { "FAIL" };
    let checklist = serde_json::json!({
        "adapterId": configuration.adapter_id,
        "callbackOrPollVerified": callback_or_poll_verified,
        "credentialRevisionVerified": credential_verified,
        "killSwitchInactive": !blockers.contains(&"KILL_SWITCH_ACTIVE"),
        "killSwitchCodePresent": !configuration.kill_switch_code.is_empty(),
        "liveSandbox": live_sandbox,
        "redacted": true,
    });
    let provider_evidence_digest = sha256_hex(
        format!(
            "{}:{}:{}:{result}:{checklist}",
            revision.config_id, revision.config_version, revision.configuration_digest
        )
        .as_bytes(),
    );
    PreflightEvidence {
        result,
        checklist,
        blockers,
        provider_evidence_digest,
    }
}

async fn persist_preflight_receipt(
    pool: &sqlx::PgPool,
    provider_connection_test_id: uuid::Uuid,
    revision: &ProviderRevision,
    evidence: PreflightEvidence,
) -> Result<serde_json::Value, HttpResponse> {
    let receipt = match sqlx::query_scalar!(
        "SELECT ops.record_communication_provider_preflight_v1( \
           $1,$2,$3,$4::char(64),$5,$6,$7,$8::char(64))",
        provider_connection_test_id,
        revision.config_id,
        revision.config_version,
        &revision.configuration_digest,
        evidence.result,
        evidence.checklist,
        serde_json::json!(evidence.blockers),
        evidence.provider_evidence_digest,
    )
    .fetch_one(pool)
    .await
    {
        Ok(Some(value)) => value,
        Ok(None) | Err(_) => {
            return Err(problem("COMMUNICATION_PREFLIGHT_PERSISTENCE_FAILED", 503));
        }
    };
    Ok(receipt)
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
