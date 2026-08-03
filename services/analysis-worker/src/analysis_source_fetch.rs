use super::*;
use gurine_agent_orchestration::research::{
    ResearchRedirect, ResearchRequestKind, ResearchSafeHeader, Sha256Digest,
};
use gurine_persistence_postgres::research_artifacts::{
    ResearchArtifactRepository, ResearchArtifactRepositoryError, ResearchFetchWrite,
};

mod output;
mod pending;
mod rights;
mod validation;

use rights::{SourceUseRootInput, build_source_use_root, project_rights};

const INITIAL_RESEARCH_CLASSIFICATION: &str = "RESTRICTED";
const INITIAL_RESEARCH_REVIEW_TIER: &str = "OFFICIAL_UNREVIEWED";

pub(super) struct PendingSourceFetch {
    pub(super) request_kind: &'static str,
    pub(super) source_id: &'static str,
    pub(super) external_locator: String,
    pub(super) source_url_redacted: Option<String>,
    pub(super) final_url_redacted: Option<String>,
    pub(super) http_status: i32,
    pub(super) content_media_type: Option<String>,
    pub(super) request_sha256: String,
    pub(super) content: Vec<u8>,
    pub(super) object_key: String,
    pub(super) policy_version: &'static str,
    pub(super) fetch_id: Uuid,
    pub(super) asset_id: Uuid,
    pub(super) artifact_id: Uuid,
    pub(super) source_use_id: Uuid,
    pub(super) source_use_sha256: String,
    pub(super) safe_headers: Value,
    pub(super) redirects: Value,
    pub(super) content_safety_receipt_sha256: String,
}

struct FetchedResponse {
    status: u16,
    content_type: Option<String>,
    safe_headers: Value,
    redirects: Value,
    bytes: Vec<u8>,
    response_sha256: String,
    gateway_receipt_sha256: String,
}

pub(super) async fn dispatch_source_fetch(
    state: &State,
    turn: &ProviderTurnIdentity,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    request: &gurine_agent_orchestration::runtime::SourceFetchRequest,
) -> Result<(Value, Option<PendingSourceFetch>), Failure> {
    let channel = source_egress_channel(state, turn)?;
    let v2 = request
        .to_v2()
        .map_err(|_| Failure::Terminal("SOURCE_FETCH_REQUEST_INVALID", "v2".to_owned()))?;
    let (
        target,
        source_id,
        request_kind,
        requested_limit,
        expected_media_types,
        max_bytes,
        allow_redirects,
    ) = validation::source_target(&v2)?;
    let rights = fetch_rights(state, source_id, request_kind).await?;
    let fetched = read_source_response(
        &state.client,
        channel,
        target.as_str(),
        source_id,
        turn.turn_id,
        &call.call_id.to_string(),
        &call.request_sha256,
        request_kind,
        &expected_media_types,
        max_bytes,
        allow_redirects,
    )
    .await?;
    finish_source_fetch(
        state,
        turn,
        call,
        target,
        source_id,
        request_kind,
        requested_limit,
        rights,
        fetched,
    )
    .await
}

#[expect(
    clippy::too_many_arguments,
    reason = "source completion binds fetch, rights, and wire output"
)]
async fn finish_source_fetch(
    state: &State,
    turn: &ProviderTurnIdentity,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    target: reqwest::Url,
    source_id: &'static str,
    request_kind: &'static str,
    requested_limit: usize,
    rights: Value,
    fetched: FetchedResponse,
) -> Result<(Value, Option<PendingSourceFetch>), Failure> {
    let safety_receipt = clean_content_receipt(&fetched.bytes, fetched.content_type.as_deref())?;
    let policy_version = "source-policy-v2";
    let policy_sha256 = sha256(policy_version.as_bytes());
    let decision_sha256 = sha256(format!("{policy_version}:ALLOW:{request_kind}").as_bytes());
    let (pending, retrieved_at, receipt_digest) = pending::build_pending_source_fetch(
        state,
        turn,
        call,
        target,
        source_id,
        request_kind,
        fetched.status,
        fetched.content_type,
        fetched.bytes.clone(),
        fetched.response_sha256.clone(),
        fetched.safe_headers,
        fetched.redirects,
        policy_version,
        safety_receipt,
        rights,
    )
    .await?;
    let pricing = brave_pricing(state, request_kind).await?;
    let output = output::build_fetch_output(
        request_kind,
        &fetched.bytes,
        requested_limit,
        &call.request_sha256,
        fetched.status,
        &policy_sha256,
        &decision_sha256,
        &retrieved_at,
        receipt_digest,
        &pending,
        pending.artifact_id,
        pending.asset_id,
        pending.fetch_id,
        source_id,
        &pending.external_locator,
        pricing.as_ref(),
        fetched.response_sha256,
        &pending.safe_headers,
        &pending.redirects,
        &fetched.gateway_receipt_sha256,
    )?;
    Ok((output, Some(pending)))
}

fn source_egress_channel<'a>(
    state: &'a State,
    turn: &ProviderTurnIdentity,
) -> Result<&'a reqwest::Url, Failure> {
    state
        .config
        .egress_source_url
        .as_ref()
        .ok_or_else(|| Failure::Terminal("SOURCE_EGRESS_MISSING", turn.run_id.to_string()))
}

async fn fetch_rights(
    state: &State,
    source_id: &str,
    request_kind: &str,
) -> Result<Value, Failure> {
    let rights: Option<Value> = sqlx::query_scalar!(
        "SELECT ops.assert_research_fetch_rights_v1($1,$2)",
        source_id,
        request_kind,
    )
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    rights.ok_or_else(|| {
        Failure::Terminal(
            "SOURCE_RIGHTS_UNAVAILABLE",
            format!("{source_id}:{request_kind}"),
        )
    })
}

fn clean_content_receipt(bytes: &[u8], content_type: Option<&str>) -> Result<String, Failure> {
    let safety = validation::scan_fetched_content(bytes, content_type);
    if safety.state == "CLEAN" {
        return Ok(safety.receipt_sha256);
    }
    Err(Failure::Terminal(
        "SOURCE_CONTENT_QUARANTINED",
        safety.receipt_sha256,
    ))
}

async fn brave_pricing(state: &State, request_kind: &str) -> Result<Option<Value>, Failure> {
    if request_kind != "SEARCH_PUBLIC_WEB" {
        return Ok(None);
    }
    sqlx::query_scalar!("SELECT ops.brave_search_pricing_v1()")
        .fetch_one(&state.pool)
        .await
        .map_err(database)?
        .ok_or_else(|| {
            database(sqlx::Error::Decode(Box::new(
                sqlx::error::UnexpectedNullError,
            )))
        })
        .map(Some)
}

#[expect(
    clippy::too_many_arguments,
    reason = "source fetch binds the provider request and bounded response policy"
)]
async fn read_source_response(
    client: &reqwest::Client,
    channel: &reqwest::Url,
    target: &str,
    source_id: &str,
    turn_id: Uuid,
    call_id: &str,
    request_sha256: &str,
    request_kind: &str,
    expected_media_types: &[String],
    max_bytes: u64,
    allow_redirects: bool,
) -> Result<FetchedResponse, Failure> {
    let request = source_request(
        client,
        channel,
        target,
        source_id,
        turn_id,
        call_id,
        request_sha256,
        expected_media_types,
        max_bytes,
        allow_redirects,
    );
    let response = request
        .send()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_FETCH_UNKNOWN", error.to_string()))?;
    let (content_type, safe_headers, redirects, gateway_receipt_sha256) =
        response_metadata(&response)?;
    let status = response.status().as_u16();
    let successful = response.status().is_success();
    if response.status().is_redirection() && !allow_redirects {
        return Err(Failure::Terminal(
            "SOURCE_REDIRECT_DENIED",
            status.to_string(),
        ));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_FETCH_UNKNOWN", error.to_string()))?
        .to_vec();
    validate_source_response(
        &bytes,
        max_bytes,
        request_kind,
        expected_media_types,
        content_type.as_deref(),
        successful,
        status,
    )?;
    Ok(FetchedResponse {
        status,
        content_type,
        safe_headers,
        redirects,
        response_sha256: sha256(&bytes),
        gateway_receipt_sha256,
        bytes,
    })
}

#[expect(
    clippy::too_many_arguments,
    reason = "source fetch binds the provider request and bounded response policy"
)]
fn source_request(
    client: &reqwest::Client,
    channel: &reqwest::Url,
    target: &str,
    source_id: &str,
    turn_id: Uuid,
    call_id: &str,
    request_sha256: &str,
    expected_media_types: &[String],
    max_bytes: u64,
    allow_redirects: bool,
) -> reqwest::RequestBuilder {
    let mut request = client
        .get(channel.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-egress-target", target)
        .header("x-gurine-source-id", source_id)
        .header("x-gurine-source-fetch-id", turn_id.to_string())
        .header(
            "x-gurine-allow-redirects",
            if allow_redirects { "true" } else { "false" },
        )
        .header("x-gurine-source-fetch-max-bytes", max_bytes.to_string())
        .header("x-gurine-source-fetch-request-sha256", request_sha256);
    if !expected_media_types.is_empty() {
        request = request.header(
            "x-gurine-source-fetch-expected-media-types",
            serde_json::to_string(expected_media_types).unwrap_or_else(|_| "[]".to_owned()),
        );
    }
    request = request.header(
        "x-gurine-idempotency-key",
        format!("source-fetch:{turn_id}:{call_id}:{request_sha256}"),
    );
    request
}

fn response_metadata(
    response: &reqwest::Response,
) -> Result<(Option<String>, Value, Value, String), Failure> {
    let status = response.status().as_u16();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(|value| {
            value
                .split(';')
                .next()
                .unwrap_or(value)
                .trim()
                .to_ascii_lowercase()
        });
    let safe_header_names = [
        "content-type",
        "content-length",
        "content-language",
        "etag",
        "last-modified",
        "cache-control",
        "date",
        "location",
    ];
    let safe_headers = Value::Array(safe_header_names.iter().filter_map(|name| {
        let value = response.headers().get(*name)?.to_str().ok()?;
        // A redirect location may contain path/query identifiers.  Keep its
        // digest as immutable fetch metadata, but never echo the raw value to
        // the model-facing tool response.
        let safe_value = if *name == "location" {
            Value::Null
        } else {
            Value::String(value.to_owned())
        };
        Some(json!({"name": name, "safeValue": safe_value, "valueSha256": sha256(value.as_bytes())}))
    }).collect());
    let redirects = response
        .headers()
        .get("x-gurine-source-fetch-redirect-chain")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| serde_json::from_str::<Value>(value).ok())
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let redirects = validation::normalize_redirect_chain(redirects)?;
    let gateway_receipt_sha256 = response
        .headers()
        .get("x-gurine-egress-receipt-sha256")
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| Failure::Terminal("SOURCE_GATEWAY_RECEIPT_MISSING", status.to_string()))?
        .to_owned();
    Ok((
        content_type,
        safe_headers,
        redirects,
        gateway_receipt_sha256,
    ))
}

fn validate_source_response(
    bytes: &[u8],
    max_bytes: u64,
    request_kind: &str,
    expected_media_types: &[String],
    content_type: Option<&str>,
    successful: bool,
    status: u16,
) -> Result<(), Failure> {
    if bytes.len() > max_bytes as usize {
        return Err(Failure::Terminal(
            "SOURCE_FETCH_TOO_LARGE",
            max_bytes.to_string(),
        ));
    }
    if request_kind == "FETCH_URL" {
        let actual = content_type.unwrap_or_default();
        if !expected_media_types
            .iter()
            .any(|expected| expected == actual)
        {
            return Err(Failure::Terminal(
                "SOURCE_MEDIA_TYPE_UNEXPECTED",
                actual.to_owned(),
            ));
        }
    }
    if !successful {
        return Err(Failure::Terminal(
            "SOURCE_FETCH_DENIED",
            format!("status:{status}"),
        ));
    }
    Ok(())
}

pub(super) async fn persist_research_fetch(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    tool_call_id: Uuid,
    call_id: &str,
    result_sha256: &str,
    source: &PendingSourceFetch,
) -> Result<(), Failure> {
    let request_kind = ResearchRequestKind::parse(source.request_kind)
        .map_err(|_| Failure::Terminal("SOURCE_ARTIFACT_INVALID", "request_kind".to_owned()))?;
    let safe_headers =
        serde_json::from_value::<Vec<ResearchSafeHeader>>(source.safe_headers.clone())
            .map_err(|_| Failure::Terminal("SOURCE_ARTIFACT_INVALID", "safe_headers".to_owned()))?;
    let redirect_chain = serde_json::from_value::<Vec<ResearchRedirect>>(source.redirects.clone())
        .map_err(|_| Failure::Terminal("SOURCE_ARTIFACT_INVALID", "redirect_chain".to_owned()))?;
    let write = ResearchFetchWrite {
        request_kind,
        agent_run_id: turn.run_id,
        provider_turn_id: turn.turn_id,
        tool_call_id,
        call_id,
        input_snapshot_sha256: research_digest(
            &turn.input_snapshot_sha256,
            "input_snapshot_sha256",
        )?,
        source_id: source.source_id,
        external_locator: &source.external_locator,
        source_url_redacted: source.source_url_redacted.as_deref(),
        final_url_redacted: source.final_url_redacted.as_deref(),
        http_status: u16::try_from(source.http_status)
            .map_err(|_| Failure::Terminal("SOURCE_ARTIFACT_INVALID", "http_status".to_owned()))?,
        content_media_type: source.content_media_type.as_deref(),
        request_sha256: research_digest(&source.request_sha256, "request_sha256")?,
        content: &source.content,
        object_key: &source.object_key,
        policy_version: source.policy_version,
        result_sha256: research_digest(result_sha256, "result_sha256")?,
        fetch_id: source.fetch_id,
        asset_id: source.asset_id,
        artifact_id: source.artifact_id,
        source_use_id: source.source_use_id,
        source_use_sha256: research_digest(&source.source_use_sha256, "source_use_sha256")?,
        content_safety_receipt_sha256: research_digest(
            &source.content_safety_receipt_sha256,
            "content_safety_receipt_sha256",
        )?,
        safe_headers,
        redirect_chain,
    };
    let repository = ResearchArtifactRepository::new();
    match request_kind {
        ResearchRequestKind::SearchPublicWeb => {
            repository.record_discovery(executor, &write).await?;
        }
        ResearchRequestKind::FetchUrl => {
            repository.insert_or_replay(executor, &write).await?;
        }
    }
    Ok(())
}

fn research_digest(value: &str, field: &'static str) -> Result<Sha256Digest, Failure> {
    Sha256Digest::parse(value)
        .map_err(|_| Failure::Terminal("SOURCE_ARTIFACT_INVALID", field.to_owned()))
}

impl From<ResearchArtifactRepositoryError> for Failure {
    fn from(error: ResearchArtifactRepositoryError) -> Self {
        match error {
            ResearchArtifactRepositoryError::Database(source) => database(source),
            other => Failure::Terminal("SOURCE_ARTIFACT_INVALID", other.to_string()),
        }
    }
}
