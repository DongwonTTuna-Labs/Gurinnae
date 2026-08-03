use actix_web::{HttpRequest, HttpResponse, http::Method, web};
use serde_json::{Map, Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use super::callbacks_support::{
    auth_method, callback_channel, callback_env_name, callback_key, canonical_json, encrypt,
    env_name, hex_bytes, is_digest, key_id, operation_id, sha256_hex, smtp_item, verify_signature,
};
use super::{GatewayState, header, problem};

const JSON_BODY_LIMIT: usize = 2_097_152;
const SMTP_BODY_LIMIT: usize = 10_485_760;

#[derive(Clone)]
struct Revision {
    config_id: Uuid,
    version: i64,
    config_digest: String,
    preflight_id: Uuid,
    preflight_digest: String,
    channel: &'static str,
}

pub async fn communication_callback(
    request: HttpRequest,
    path: web::Path<(String, String)>,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    let (channel, integration) = path.into_inner();
    receive(request, channel, integration, body, state, false).await
}

pub async fn communication_callback_smtp(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    let integration = header(&request, "x-gurine-provider-integration-id")
        .unwrap_or_default()
        .to_owned();
    receive(
        request,
        "smtp-dsn".to_owned(),
        integration,
        body,
        state,
        true,
    )
    .await
}

pub async fn communication_callback_smtp_with_integration(
    request: HttpRequest,
    path: web::Path<String>,
    body: web::Bytes,
    state: web::Data<GatewayState>,
) -> HttpResponse {
    receive(
        request,
        "smtp-dsn".to_owned(),
        path.into_inner(),
        body,
        state,
        true,
    )
    .await
}

async fn receive(
    request: HttpRequest,
    channel_path: String,
    integration_path: String,
    body: web::Bytes,
    state: web::Data<GatewayState>,
    smtp: bool,
) -> HttpResponse {
    let limit = if smtp {
        SMTP_BODY_LIMIT
    } else {
        JSON_BODY_LIMIT
    };
    if request.method() != Method::POST || body.is_empty() || body.len() > limit {
        return problem("CALLBACK_BODY_INVALID", 413);
    }
    let Some(pool) = state.database.as_ref() else {
        return problem("COMMUNICATION_DATABASE_REQUIRED", 503);
    };
    let Some(channel) = callback_channel(&channel_path, smtp) else {
        return problem("CALLBACK_CHANNEL_UNSUPPORTED", 404);
    };
    let Some(integration_id) = Uuid::parse_str(&integration_path).ok() else {
        return problem("CALLBACK_INTEGRATION_REQUIRED", 400);
    };
    let Some(revision) = load_revision(&request, channel, integration_id, pool).await else {
        return problem("CALLBACK_PROVIDER_REVISION_INVALID", 403);
    };
    let Some((mut payload, auth_digest, auth_evidence)) =
        authenticate_and_parse(&request, &body, channel, smtp)
    else {
        return problem("CALLBACK_AUTH_INVALID", 401);
    };
    if !normalize_payload(
        &mut payload,
        &request,
        &body,
        &revision,
        &auth_digest,
        &auth_evidence,
        smtp,
    ) {
        return problem("CALLBACK_PAYLOAD_INVALID", 400);
    }
    match sqlx::query_scalar!(
        "SELECT ops.record_communication_callback_request_json($1::jsonb)",
        payload,
    )
    .fetch_one(pool)
    .await
    {
        Ok(Some(receipt)) => HttpResponse::Ok().json(receipt),
        Ok(None) | Err(_) => problem("CALLBACK_RECORD_FAILED", 502),
    }
}

async fn load_revision(
    request: &HttpRequest,
    channel: &'static str,
    integration_id: Uuid,
    pool: &PgPool,
) -> Option<Revision> {
    let config_id = header(request, "x-gurine-provider-config-id")?
        .parse::<Uuid>()
        .ok()?;
    let version = header(request, "x-gurine-provider-config-version")?
        .parse::<i64>()
        .ok()?;
    let config_digest = header(request, "x-gurine-provider-configuration-digest")?;
    let preflight_id = header(request, "x-gurine-provider-preflight-receipt-id")
        .and_then(|value| value.parse::<Uuid>().ok())?;
    let preflight_digest = header(request, "x-gurine-provider-preflight-receipt-digest")?;
    let secret_reference = std::env::var(format!(
        "COMMUNICATION_{}_CALLBACK_SECRET_REFERENCE",
        callback_env_name(channel),
    ))
    .ok()
    .filter(|value| !value.trim().is_empty())?;
    let valid = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM ops.communication_provider_configs pc
         JOIN ops.communication_provider_preflight_receipts pf
           ON pf.provider_config_id=pc.id AND pf.provider_config_version=pc.version
          AND pf.configuration_digest=pc.configuration_digest
         WHERE pc.id=$1 AND pc.version=$2 AND pc.configuration_digest=$3
           AND pc.integration_id=$4 AND pc.channel=$5
           AND pc.webhook_secret_reference=$8 AND pc.operational_state='ACTIVE'
           AND pc.activation_effective_at<=clock_timestamp()
           AND (pc.activation_expires_at IS NULL OR pc.activation_expires_at>clock_timestamp())
           AND pf.id=$6 AND pf.receipt_digest=$7 AND pf.result='PASS'
           AND pf.expires_at>clock_timestamp() AND pf.callback_or_poll_verified AND pf.live_sandbox)",
        config_id,
        version,
        config_digest,
        integration_id,
        channel,
        preflight_id,
        preflight_digest,
        secret_reference,
    )
    .fetch_one(pool)
    .await
    .ok()??;
    valid.then_some(Revision {
        config_id,
        version,
        config_digest: config_digest.to_owned(),
        preflight_id,
        preflight_digest: preflight_digest.to_owned(),
        channel,
    })
}

fn authenticate_and_parse(
    request: &HttpRequest,
    body: &[u8],
    channel: &str,
    smtp: bool,
) -> Option<(Value, String, Value)> {
    let (digest, evidence) = if smtp {
        let content_type = header(request, "content-type")?;
        if !content_type.eq_ignore_ascii_case("multipart/report; report-type=delivery-status") {
            return None;
        }
        let assertion = header(request, "x-gurine-mta-assertion")?;
        if assertion.trim().is_empty() {
            return None;
        }
        (
            sha256_hex(assertion.as_bytes()),
            json!({"method":"GURINE_MTA_ASSERTION","assertionDigest":sha256_hex(assertion.as_bytes())}),
        )
    } else {
        let signature = header(request, "x-gurine-callback-signature")?;
        let secret = std::env::var(format!(
            "COMMUNICATION_{}_CALLBACK_SECRET",
            env_name(channel)
        ))
        .ok()?;
        if !verify_signature(&secret, body, signature) {
            return None;
        }
        let method = auth_method(channel);
        (
            sha256_hex(signature.as_bytes()),
            json!({"method":method,"signatureVerified":true}),
        )
    };
    let payload = if smtp {
        let items = json!({
            "contractVersion":"communication-callback-items-v1",
            "items":[smtp_item(body)]
        });
        json!({"normalized_items":items,"normalized_item_set_digest":sha256_hex(items.to_string())})
    } else {
        serde_json::from_slice(body).ok().filter(Value::is_object)?
    };
    Some((payload, digest, evidence))
}

fn normalize_payload(
    payload: &mut Value,
    request: &HttpRequest,
    body: &[u8],
    revision: &Revision,
    auth_digest: &str,
    auth_evidence: &Value,
    smtp: bool,
) -> bool {
    let Some(object) = payload.as_object_mut() else {
        return false;
    };
    let items = object
        .get("normalized_items")
        .cloned()
        .unwrap_or(Value::Null);
    let count = items
        .get("items")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let set_digest = if smtp {
        let digest = sha256_hex(canonical_json(&items).to_string().as_bytes());
        object.insert("normalized_item_set_digest".into(), json!(digest.clone()));
        digest
    } else {
        object
            .get("normalized_item_set_digest")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    if count == 0 || !is_digest(&set_digest) || !valid_items(&items, count) {
        return false;
    }
    let request_digest = sha256_hex(body);
    let replay = header(request, "x-gurine-callback-replay-key")
        .unwrap_or(&request_digest)
        .to_owned();
    let Some(key) = callback_key() else {
        return false;
    };
    let ack = br#"{}"#;
    let Some(request_ciphertext) = encrypt(&key, body) else {
        return false;
    };
    let Some(ack_ciphertext) = encrypt(&key, ack) else {
        return false;
    };
    let content_type = if smtp {
        "multipart/report; report-type=delivery-status"
    } else {
        "application/json"
    };
    insert_common(
        object,
        revision,
        request,
        body,
        request_digest,
        &replay,
        content_type,
        auth_digest,
        auth_evidence,
        request_ciphertext,
        ack_ciphertext,
        ack,
    );
    object.insert("normalized_items".into(), items);
    object.insert("item_count".into(), json!(count));
    object.entry("applied_item_count").or_insert(json!(count));
    object.entry("stale_item_count").or_insert(json!(0));
    object.entry("unmatched_item_count").or_insert(json!(0));
    object
        .entry("processing_disposition")
        .or_insert(json!("AUTHENTICATED_APPLIED"));
    true
}

#[allow(clippy::too_many_arguments)]
fn insert_common(
    object: &mut Map<String, Value>,
    revision: &Revision,
    request: &HttpRequest,
    body: &[u8],
    request_digest: String,
    replay: &str,
    content_type: &str,
    auth_digest: &str,
    auth_evidence: &Value,
    request_ciphertext: Vec<u8>,
    ack_ciphertext: Vec<u8>,
    ack: &[u8],
) {
    let auth_method = if revision.channel == "SMTP_EMAIL" {
        "GURINE_MTA_ASSERTION"
    } else {
        auth_method(revision.channel)
    };
    insert_revision(
        object,
        revision,
        auth_method,
        operation_id(revision.channel),
    );
    insert_request(
        object,
        request,
        body,
        request_digest.clone(),
        content_type,
        request_ciphertext,
    );
    insert_auth(object, auth_method, auth_evidence, auth_digest, replay);
    insert_ack(object, ack_ciphertext, ack, &request_digest);
}

fn insert_revision(
    object: &mut Map<String, Value>,
    revision: &Revision,
    auth_method: &str,
    operation: &str,
) {
    object.extend([
        (
            "provider_preflight_receipt_id".into(),
            json!(revision.preflight_id),
        ),
        ("provider_config_id".into(), json!(revision.config_id)),
        ("provider_config_version".into(), json!(revision.version)),
        (
            "provider_configuration_digest".into(),
            json!(revision.config_digest),
        ),
        (
            "provider_preflight_receipt_digest".into(),
            json!(revision.preflight_digest),
        ),
        ("channel".into(), json!(revision.channel)),
        ("callback_operation_id".into(), json!(operation)),
        ("authentication_method".into(), json!(auth_method)),
    ]);
}

#[allow(clippy::too_many_arguments)]
fn insert_request(
    object: &mut Map<String, Value>,
    request: &HttpRequest,
    body: &[u8],
    request_digest: String,
    content_type: &str,
    ciphertext: Vec<u8>,
) {
    object.extend([
        (
            "callback_request_digest".into(),
            json!(request_digest.clone()),
        ),
        ("http_method".into(), json!("POST")),
        ("request_content_type".into(), json!(content_type)),
        (
            "request_target_digest".into(),
            json!(sha256_hex(request.uri().path().as_bytes())),
        ),
        (
            "request_header_digest".into(),
            json!(header(request, "x-gurine-callback-header-digest").unwrap_or(&request_digest)),
        ),
        ("request_body_sha256".into(), json!(request_digest)),
        ("request_body_length".into(), json!(body.len())),
        (
            "request_body_ciphertext".into(),
            json!(format!("\\x{}", hex_bytes(&ciphertext))),
        ),
        ("request_encryption_key_id".into(), json!(key_id())),
    ]);
}

fn insert_auth(
    object: &mut Map<String, Value>,
    method: &str,
    evidence: &Value,
    digest: &str,
    replay: &str,
) {
    object.extend([
        ("authentication_evidence".into(), evidence.clone()),
        (
            "authentication_evidence_digest".into(),
            json!(sha256_hex(digest.as_bytes())),
        ),
        (
            "provider_request_identity_hmac".into(),
            json!(sha256_hex(replay.as_bytes())),
        ),
        (
            "replay_key_digest".into(),
            json!(sha256_hex(replay.as_bytes())),
        ),
        ("authentication_method".into(), json!(method)),
    ]);
}

fn insert_ack(
    object: &mut Map<String, Value>,
    ciphertext: Vec<u8>,
    ack: &[u8],
    request_digest: &str,
) {
    object.extend([
        ("acknowledgement_http_status".into(), json!(200)),
        (
            "acknowledgement_content_type".into(),
            json!("application/json"),
        ),
        (
            "acknowledgement_headers".into(),
            json!({"content-type":"application/json"}),
        ),
        (
            "acknowledgement_body_ciphertext".into(),
            json!(format!("\\x{}", hex_bytes(&ciphertext))),
        ),
        ("acknowledgement_body_sha256".into(), json!(sha256_hex(ack))),
        ("acknowledgement_body_length".into(), json!(ack.len())),
        ("acknowledgement_encryption_key_id".into(), json!(key_id())),
        ("acknowledgement_digest".into(), json!(sha256_hex(ack))),
        (
            "verification_receipt_digest".into(),
            json!(sha256_hex(format!("verify:{}", request_digest).as_bytes())),
        ),
        (
            "callback_digest".into(),
            json!(sha256_hex(
                format!("callback:{}", request_digest).as_bytes()
            )),
        ),
    ]);
}

fn valid_items(items: &Value, count: usize) -> bool {
    let Some(values) = items.get("items").and_then(Value::as_array) else {
        return false;
    };
    items
        .get("contractVersion")
        .and_then(Value::as_str)
        .is_some_and(|v| v == "communication-callback-items-v1")
        && values.len() == count
        && values.iter().enumerate().all(|(idx, item)| {
            item.get("ordinal").and_then(Value::as_u64) == Some(idx as u64)
                && item.get("effectKind").is_some()
                && item
                    .get("providerEventIdentityHmac")
                    .and_then(Value::as_str)
                    .is_some_and(is_digest)
                && item
                    .get("itemDigest")
                    .and_then(Value::as_str)
                    .is_some_and(is_digest)
                && item
                    .get("normalizedEvidenceDigest")
                    .and_then(Value::as_str)
                    .is_some_and(is_digest)
        })
}
