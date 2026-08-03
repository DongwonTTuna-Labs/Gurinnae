use super::*;

mod output;
mod pending;
mod validation;

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
        Some(json!({"name": name, "safeValue": value, "valueSha256": sha256(value.as_bytes())}))
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

struct RightsProjection {
    capability_id: String,
    occurred_at: String,
    expires_at: Value,
    dimensions: Value,
    digest: String,
}

fn project_rights(
    rights: &Value,
    artifact_id: Uuid,
    asset_id: Uuid,
    content_sha256: &str,
    policy_version: &str,
    source_id: &str,
) -> Result<RightsProjection, Failure> {
    let capability_id = rights
        .get("decisionId")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "decisionId".to_owned()))?
        .to_owned();
    let capability_version = rights
        .get("decisionVersion")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "decisionVersion".to_owned()))?;
    let capability_digest = rights
        .get("decisionSha256")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "decisionSha256".to_owned()))?
        .to_owned();
    let occurred_at = rights
        .get("effectiveAt")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "effectiveAt".to_owned()))?
        .to_owned();
    let expires_at = rights.get("expiresAt").cloned().unwrap_or(Value::Null);
    let dimensions = rights
        .get("dimensions")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let right = |name: &str| {
        dimensions
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN")
    };
    let identity = json!({
        "schemaVersion":"asset-rights-decision.v1","decisionId":asset_id,"assetId":asset_id,
        "assetSha256":content_sha256,"assetRevision":1,"decisionVersion":1,
        "assetKind":"RESEARCH_ARTIFACT","researchArtifactId":artifact_id,"decisionKind":"GRANT",
        "accessRight":right("accessRight"),"privateStorageRight":right("privateStorageRight"),
        "modelEgressRight":right("modelEgressRight"),"modelUseRight":right("modelUseRight"),
        "derivativeCreationRight":right("derivativeCreationRight"),"excerptRight":right("excerptRight"),
        "redistributionRight":right("redistributionRight"),"commercialUseRight":right("commercialUseRight"),
        "publicDisplayRight":right("publicDisplayRight"),"policyVersion":policy_version,
        "policySha256":sha256(policy_version.as_bytes()),"legalBasisCode":"PUBLIC_RESEARCH",
        "legalBasisReference":source_id,"jurisdiction":"GLOBAL","attributionRequired":false,
        "effectiveAt":occurred_at,"expiresAt":expires_at,"capabilityDecisionId":capability_id,
        "capabilityDecisionVersion":capability_version,"capabilityDecisionSha256":capability_digest
    });
    Ok(RightsProjection {
        capability_id,
        occurred_at,
        expires_at,
        dimensions,
        digest: sha256(&canonical_bytes(&identity)?),
    })
}

struct SourceUseRootInput<'a> {
    source_use_id: Uuid,
    turn: &'a ProviderTurnIdentity,
    call: &'a gurine_agent_orchestration::runtime::ToolCall,
    artifact_id: Uuid,
    asset_id: Uuid,
    fetch_id: Uuid,
    artifact_sha256: &'a str,
    content_sha256: &'a str,
    locator: &'a str,
    rights: &'a RightsProjection,
}

fn build_source_use_root(input: &SourceUseRootInput<'_>) -> Value {
    let SourceUseRootInput {
        source_use_id,
        turn,
        call,
        artifact_id,
        asset_id,
        fetch_id,
        artifact_sha256,
        content_sha256,
        locator,
        rights,
    } = input;
    let right = |name: &str| {
        rights
            .dimensions
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN")
    };
    json!({
        "schemaVersion":"source-use.v2","sourceUseId":source_use_id,"agentRunId":turn.run_id,
        "providerTurnId":turn.turn_id,"toolCallId":call.call_id,"parentSourceUseId":Value::Null,
        "parentSourceUseSha256":Value::Null,"useKind":"TOOL_QUERY","sourceKind":"RESEARCH_ARTIFACT",
        "sourceIdentity":{"kind":"RESEARCH_ARTIFACT","researchArtifactId":artifact_id,"assetId":asset_id,
            "assetRevision":1,"artifactSha256":artifact_sha256,"contentSha256":content_sha256,"sourceFetchId":fetch_id},
        "locator":{"kind":"HTML_CSS_SELECTOR","value":locator,"locatorSha256":sha256(locator.as_bytes())},
        "selectedContentSha256":content_sha256,"classification":"PUBLIC",
        "rightsDecision":{"decisionId":asset_id,"capabilityDecisionId":rights.capability_id,
            "decisionVersion":1,"decisionSha256":rights.digest,"effectiveAt":rights.occurred_at,
            "expiresAt":rights.expires_at,"accessRight":right("accessRight"),
            "privateStorageRight":right("privateStorageRight"),"modelEgressRight":right("modelEgressRight"),
            "modelUseRight":right("modelUseRight"),"derivativeCreationRight":right("derivativeCreationRight"),
            "excerptRight":right("excerptRight"),"redistributionRight":right("redistributionRight"),
            "commercialUseRight":right("commercialUseRight"),"publicDisplayRight":right("publicDisplayRight")},
        "providerReceiptId":Value::Null,"occurredAt":rights.occurred_at
    })
}

pub(super) async fn persist_research_fetch(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    tool_call_id: Uuid,
    call_id: &str,
    result_sha256: &str,
    source: &PendingSourceFetch,
) -> Result<(), Failure> {
    let _: Value = sqlx::query_scalar!(
        "SELECT ops.record_research_fetch_v1($1,$2,$3,$4,CAST($5 AS char(64)),$6,$7,$8,$9,$10,$11,$12,CAST($13 AS char(64)),$14,$15,$16,CAST($17 AS char(64)),$18,$19,$20,$21,$22,CAST($23 AS char(64)),$24,$25)",
        turn.run_id,
        turn.turn_id,
        tool_call_id,
        call_id,
        &turn.input_snapshot_sha256,
        source.request_kind,
        source.source_id,
        &source.external_locator,
        source.source_url_redacted.as_deref(),
        source.final_url_redacted.as_deref(),
        source.http_status,
        source.content_media_type.as_deref(),
        &source.request_sha256,
        &source.content,
        &source.object_key,
        source.policy_version,
        result_sha256,
        source.fetch_id,
        source.asset_id,
        source.artifact_id,
        source.source_use_id,
        &source.source_use_sha256,
        &source.content_safety_receipt_sha256,
        &source.safe_headers,
        &source.redirects,
    )
    .fetch_one(&mut *executor)
    .await
    .map_err(database)?
    .ok_or_else(|| database(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?;
    Ok(())
}
