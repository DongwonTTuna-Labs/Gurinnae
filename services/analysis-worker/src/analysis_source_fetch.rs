use super::*;

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

type SourceTarget = (
    reqwest::Url,
    &'static str,
    &'static str,
    usize,
    Vec<String>,
    u64,
    bool,
);

struct FetchedResponse {
    status: u16,
    content_type: Option<String>,
    safe_headers: Value,
    redirects: Value,
    bytes: Vec<u8>,
    response_sha256: String,
    gateway_receipt_sha256: String,
}

#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct BraveSearchResponse {
    web: BraveWeb,
}

#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct BraveWeb {
    results: Vec<BraveResult>,
}

#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct BraveResult {
    title: String,
    url: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    age: Option<String>,
}

pub(super) async fn dispatch_source_fetch(
    state: &State,
    turn: &ProviderTurnIdentity,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    request: &gurine_agent_orchestration::runtime::SourceFetchRequest,
) -> Result<(Value, Option<PendingSourceFetch>), Failure> {
    let Some(channel) = state.config.egress_source_url.as_ref() else {
        return Err(Failure::Terminal("SOURCE_EGRESS_MISSING", turn.run_id.to_string()));
    };
    let v2 = request
        .to_v2()
        .map_err(|_| Failure::Terminal("SOURCE_FETCH_REQUEST_INVALID", "v2".to_owned()))?;
    let (target, source_id, request_kind, requested_limit, expected_media_types, max_bytes, allow_redirects) = source_target(&v2)?;
    let rights: Option<Value> = sqlx::query_scalar(
        "SELECT ops.assert_research_fetch_rights_v1($1,$2)",
    )
    .bind(source_id)
    .bind(request_kind)
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    let Some(rights) = rights else {
        return Err(Failure::Terminal(
            "SOURCE_RIGHTS_UNAVAILABLE",
            format!("{source_id}:{request_kind}"),
        ));
    };
    let fetched = read_source_response(&state.client, channel, target.as_str(), source_id,
        turn.turn_id, &call.call_id.to_string(), &call.request_sha256, request_kind, &expected_media_types, max_bytes, allow_redirects).await?;
    let status = fetched.status;
    let content_type = fetched.content_type;
    let safe_headers = fetched.safe_headers;
    let redirects = fetched.redirects;
    let bytes = fetched.bytes;
    let response_sha256 = fetched.response_sha256;
    let gateway_receipt_sha256 = fetched.gateway_receipt_sha256;
    let safety = scan_fetched_content(&bytes, content_type.as_deref());
    if safety.state != "CLEAN" {
        // Do not persist or expose flagged content as a usable artifact.  The
        // scanner is deliberately conservative and records a deterministic
        // receipt in the terminal error for operator reconciliation.
        return Err(Failure::Terminal("SOURCE_CONTENT_QUARANTINED", safety.receipt_sha256));
    }
    let policy_version = "source-policy-v2";
    let policy_sha256 = sha256(policy_version.as_bytes());
    let decision_sha256 = sha256(format!("{policy_version}:ALLOW:{request_kind}").as_bytes());
    let (pending, retrieved_at, receipt_digest) = build_pending_source_fetch(
        state, turn, call, target, source_id, request_kind, status, content_type,
        bytes.clone(), response_sha256.clone(), safe_headers, redirects, policy_version, safety.receipt_sha256, rights).await?;
    let brave_pricing = if request_kind == "SEARCH_PUBLIC_WEB" {
        Some(sqlx::query_scalar::<_, Value>("SELECT ops.brave_search_pricing_v1()")
            .fetch_one(&state.pool).await.map_err(database)?)
    } else { None };
    let output = build_fetch_output(request_kind, &bytes, requested_limit, &call.request_sha256,
        status, &policy_sha256, &decision_sha256, &retrieved_at, receipt_digest,
        &pending, pending.artifact_id, pending.asset_id, pending.fetch_id, source_id, &pending.external_locator, brave_pricing.as_ref(),
        response_sha256, &pending.safe_headers, &pending.redirects, &gateway_receipt_sha256)?;
    Ok((output, Some(pending)))
}

#[expect(clippy::too_many_arguments, reason = "source fetch binds the provider request and bounded response policy")]
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
    let mut request = client.get(channel.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-egress-target", target)
        .header("x-gurine-source-id", source_id)
        .header("x-gurine-source-fetch-id", turn_id.to_string())
        .header("x-gurine-allow-redirects", if allow_redirects { "true" } else { "false" })
        .header("x-gurine-source-fetch-max-bytes", max_bytes.to_string())
        .header("x-gurine-source-fetch-request-sha256", request_sha256);
    if !expected_media_types.is_empty() {
        request = request.header("x-gurine-source-fetch-expected-media-types", serde_json::to_string(expected_media_types).unwrap_or_else(|_| "[]".to_owned()));
    }
    request = request.header("x-gurine-idempotency-key", format!("source-fetch:{turn_id}:{call_id}:{request_sha256}"));
    let response = request.send().await
        .map_err(|error| Failure::Retryable("SOURCE_FETCH_UNKNOWN", error.to_string()))?;
    let status = response.status().as_u16();
    let successful = response.status().is_success();
    let content_type = response.headers().get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.split(';').next().unwrap_or(value).trim().to_ascii_lowercase());
    let safe_header_names = ["content-type", "content-length", "content-language", "etag", "last-modified", "cache-control", "date", "location"];
    let safe_headers = Value::Array(safe_header_names.iter().filter_map(|name| {
        let value = response.headers().get(*name)?.to_str().ok()?;
        Some(json!({"name": name, "safeValue": value, "valueSha256": sha256(value.as_bytes())}))
    }).collect());
    let redirects = response.headers().get("x-gurine-source-fetch-redirect-chain")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| serde_json::from_str::<Value>(value).ok())
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let redirects = normalize_redirect_chain(redirects)?;
    let gateway_receipt_sha256 = response.headers().get("x-gurine-egress-receipt-sha256")
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| Failure::Terminal("SOURCE_GATEWAY_RECEIPT_MISSING", status.to_string()))?
        .to_owned();
    if response.status().is_redirection() && !allow_redirects {
        return Err(Failure::Terminal("SOURCE_REDIRECT_DENIED", status.to_string()));
    }
    let bytes = response.bytes().await
        .map_err(|error| Failure::Retryable("SOURCE_FETCH_UNKNOWN", error.to_string()))?.to_vec();
    if bytes.len() > max_bytes as usize {
        return Err(Failure::Terminal("SOURCE_FETCH_TOO_LARGE", max_bytes.to_string()));
    }
    if request_kind == "FETCH_URL" {
        let actual = content_type.as_deref().unwrap_or_default();
        if !expected_media_types.iter().any(|expected| expected == actual) {
            return Err(Failure::Terminal("SOURCE_MEDIA_TYPE_UNEXPECTED", actual.to_owned()));
        }
    }
    if !successful {
        return Err(Failure::Terminal("SOURCE_FETCH_DENIED", format!("status:{status}")));
    }
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

fn normalize_redirect_chain(value: Value) -> Result<Value, Failure> {
    let Some(items) = value.as_array() else {
        return Err(Failure::Terminal("SOURCE_REDIRECT_CHAIN_INVALID", "array".to_owned()));
    };
    if items.len() > 5 {
        return Err(Failure::Terminal("SOURCE_REDIRECT_CHAIN_INVALID", "max_redirects".to_owned()));
    }
    let mut normalized = Vec::with_capacity(items.len());
    for (index, item) in items.iter().enumerate() {
        let Some(object) = item.as_object() else {
            return Err(Failure::Terminal("SOURCE_REDIRECT_CHAIN_INVALID", "object".to_owned()));
        };
        let ordinal = object.get("ordinal").and_then(Value::as_u64);
        let from = object.get("fromOrigin").and_then(Value::as_str);
        let to = object.get("toOrigin").and_then(Value::as_str);
        let status = object.get("status").and_then(Value::as_u64);
        let dns = object.get("dnsDecisionSha256").and_then(Value::as_str);
        let policy = object.get("policyDecisionSha256").and_then(Value::as_str);
        let valid_status = matches!(status, Some(301 | 302 | 303 | 307 | 308));
        let valid_digest = |candidate: Option<&str>| {
            candidate.is_some_and(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        };
        if ordinal != Some(index as u64 + 1)
            || from.is_none()
            || to.is_none()
            || !valid_status
            || !valid_digest(dns)
            || !valid_digest(policy)
        {
            return Err(Failure::Terminal("SOURCE_REDIRECT_CHAIN_INVALID", format!("hop:{}", index + 1)));
        }
        normalized.push(json!({
            "ordinal": ordinal,
            "fromOrigin": from,
            "toOrigin": to,
            "status": status,
            "dnsDecisionSha256": dns,
            "policyDecisionSha256": policy,
        }));
    }
    Ok(Value::Array(normalized))
}

#[expect(clippy::too_many_arguments, reason = "pending source receipt binds all immutable fetch evidence")]
async fn build_pending_source_fetch(
    state: &State,
    turn: &ProviderTurnIdentity,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    target: reqwest::Url,
    source_id: &'static str,
    request_kind: &'static str,
    status: u16,
    content_type: Option<String>,
    bytes: Vec<u8>,
    response_sha256: String,
    safe_headers: Value,
    redirects: Value,
    policy_version: &'static str,
    receipt_digest: String,
    rights: Value,
) -> Result<(PendingSourceFetch, String, String), Failure> {
    let object_key = format!("research/{}/{}/{}", turn.run_id, turn.turn_id, response_sha256);
    if request_kind == "FETCH_URL" {
        let Some(store) = state.object_store.as_ref() else {
            return Err(Failure::Terminal("OBJECT_STORE_MISSING", turn.run_id.to_string()));
        };
        store.put(&object_key, bytes.clone(), &response_sha256).await
            .map_err(|_| Failure::Terminal("OBJECT_STORE_WRITE_FAILED", object_key.clone()))?;
    }
    let redacted_locator = format!("{}://{}{}", target.scheme(), target.host_str().unwrap_or_default(), target.path());
    let fetch_id = stable_uuid(format!("source-fetch:{}:{}", turn.turn_id, response_sha256).as_bytes());
    let asset_id = stable_uuid(format!("source-asset:{fetch_id}").as_bytes());
    let artifact_id = stable_uuid(format!("source-artifact:{fetch_id}").as_bytes());
    let source_use_id = stable_uuid(format!("source-use:{fetch_id}").as_bytes());
    let content_type_value = content_type.clone().unwrap_or_else(|| "application/octet-stream".to_owned());
    let artifact_identity = json!({"schemaVersion":"research-artifact.v2","researchArtifactId":artifact_id,
        "assetId":asset_id,"assetRevision":1,"sourceFetchId":fetch_id,"artifactOrdinal":0,
        "fetchOutcome":"STORED","sourceAuthority":source_id,"finalOrigin":redacted_locator,
        "httpStatus":status,"contentMediaType":content_type_value,"contentSizeBytes":bytes.len(),
        "contentSha256":response_sha256,"responseHeadersSha256":sha256(&canonical_bytes(&safe_headers)?),
        "contentSafetyState":"CLEAN","contentSafetyReceiptSha256":receipt_digest});
    let artifact_sha256 = sha256(&canonical_bytes(&artifact_identity)?);
    let rights_projection = project_rights(&rights, artifact_id, asset_id, &response_sha256, policy_version, source_id)?;
    let source_use_root = build_source_use_root(
        source_use_id,
        turn,
        call,
        artifact_id,
        asset_id,
        fetch_id,
        artifact_sha256,
        &response_sha256,
        &redacted_locator,
        &rights_projection,
    );
    let source_use_sha256 = sha256(&canonical_bytes(&source_use_root)?);
    let retrieved_at = rights_projection.occurred_at.clone();
    let pending = PendingSourceFetch {
        request_kind, source_id, external_locator: redacted_locator.clone(),
        source_url_redacted: (request_kind == "FETCH_URL").then(|| redacted_locator.clone()),
        final_url_redacted: (request_kind == "FETCH_URL").then(|| redacted_locator.clone()),
        http_status: status as i32, content_media_type: content_type, request_sha256: call.request_sha256.clone(),
        content: bytes, object_key, policy_version, fetch_id, asset_id, artifact_id, source_use_id,
        source_use_sha256, safe_headers, redirects,
        content_safety_receipt_sha256: receipt_digest.clone(),
    };
    Ok((pending, retrieved_at, receipt_digest))
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
    let capability_id = rights.get("decisionId").and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "decisionId".to_owned()))?.to_owned();
    let capability_version = rights.get("decisionVersion").and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "decisionVersion".to_owned()))?;
    let capability_digest = rights.get("decisionSha256").and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "decisionSha256".to_owned()))?.to_owned();
    let occurred_at = rights.get("effectiveAt").and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "effectiveAt".to_owned()))?.to_owned();
    let expires_at = rights.get("expiresAt").cloned().unwrap_or(Value::Null);
    let dimensions = rights.get("dimensions").cloned().unwrap_or_else(|| json!({}));
    let right = |name: &str| dimensions.get(name).and_then(Value::as_str).unwrap_or("UNKNOWN");
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
        capability_id, occurred_at, expires_at, dimensions,
        digest: sha256(&canonical_bytes(&identity)?),
    })
}

fn build_source_use_root(
    source_use_id: Uuid,
    turn: &ProviderTurnIdentity,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    artifact_id: Uuid,
    asset_id: Uuid,
    fetch_id: Uuid,
    artifact_sha256: String,
    content_sha256: &str,
    locator: &str,
    rights: &RightsProjection,
) -> Value {
    let right = |name: &str| rights.dimensions.get(name).and_then(Value::as_str).unwrap_or("UNKNOWN");
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

struct ContentSafety {
    state: &'static str,
    receipt_sha256: String,
}

fn scan_fetched_content(bytes: &[u8], media_type: Option<&str>) -> ContentSafety {
    let text = String::from_utf8_lossy(bytes).to_ascii_lowercase();
    let control_count = bytes.iter().filter(|b| **b < 0x09 || (**b > 0x0d && **b < 0x20)).count();
    let binary_suspicious = !media_type.is_some_and(|m| m.starts_with("text/") || m.contains("json") || m.contains("xml"))
        && control_count > bytes.len().saturating_div(20);
    let markers = ["ignore previous instructions", "system prompt", "begin private key", "javascript:", "<script"];
    let marker_hits = markers.iter().filter(|marker| text.contains(**marker)).count();
    // Keep the worker scanner and the owner routine's poison sentinel
    // intentionally aligned; the owner remains the final authority.
    let poison = text.contains("poison");
    let state = if binary_suspicious || poison || marker_hits >= 2 { "QUARANTINED" } else if marker_hits == 1 { "FLAGGED" } else { "CLEAN" };
    let receipt_sha256 = sha256(format!("content-safety-v2:{}:{}", sha256(bytes), state).as_bytes());
    ContentSafety { state, receipt_sha256 }
}

fn source_target(
    v2: &gurine_agent_orchestration::runtime::SourceFetchRequestV2,
) -> Result<SourceTarget, Failure> {
    use gurine_agent_orchestration::runtime::SourceFetchRequestV2;
    match v2 {
        SourceFetchRequestV2::SearchPublicWeb { query, locale, country, recency_days, result_limit, max_bytes_per_artifact, .. } => {
            let mut target = reqwest::Url::parse("https://api.search.brave.com/res/v1/web/search")
                .map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", "brave".to_owned()))?;
            let mut pairs = target.query_pairs_mut();
            pairs.append_pair("q", query);
            pairs.append_pair("count", &result_limit.to_string());
            pairs.append_pair("offset", "0");
            pairs.append_pair("country", &country.to_ascii_lowercase());
            let language = locale.split('-').next().ok_or_else(|| Failure::Terminal("SOURCE_FETCH_REQUEST_INVALID", "locale".to_owned()))?;
            pairs.append_pair("search_lang", language);
            pairs.append_pair("ui_lang", locale);
            pairs.append_pair("safesearch", "strict");
            pairs.append_pair("spellcheck", "false");
            pairs.append_pair("text_decorations", "false");
            if let Some(days) = recency_days { pairs.append_pair("freshness", &format!("{days}d")); }
            drop(pairs);
            Ok((target, "brave-search-web-v1", "SEARCH_PUBLIC_WEB", *result_limit as usize, Vec::new(), *max_bytes_per_artifact, false))
        }
        SourceFetchRequestV2::FetchUrl { url, expected_media_types, max_bytes, allow_redirects, .. } => {
            let target = reqwest::Url::parse(url).map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", "url".to_owned()))?;
            Ok((target, "public-research", "FETCH_URL", 1, expected_media_types.clone(), *max_bytes, *allow_redirects))
        }
    }
}

#[expect(clippy::too_many_arguments, reason = "source receipt output binds request, policy, gateway, and immutable artifact evidence")]
fn build_fetch_output(
    request_kind: &str,
    bytes: &[u8],
    requested_limit: usize,
    request_sha256: &str,
    status: u16,
    policy_sha256: &str,
    decision_sha256: &str,
    retrieved_at: &str,
    receipt_digest: String,
    pending: &PendingSourceFetch,
    artifact_id: Uuid,
    asset_id: Uuid,
    fetch_id: Uuid,
    source_id: &str,
    redacted_locator: &str,
    brave_pricing: Option<&Value>,
    response_sha256: String,
    safe_headers: &Value,
    redirects: &Value,
    gateway_receipt_sha256: &str,
) -> Result<Value, Failure> {
    let mut output = json!({"schemaVersion":"source.fetch.response.v2","requestKind":request_kind,
        "gatewayDecision":{"policyVersion":"source-policy-v2","policySha256":policy_sha256,"decision":"ALLOW","decisionCode":"EGRESS_FETCHED","decisionSha256":decision_sha256},
        "discoveryReceipt":null,"searchResults":[],"artifacts":[],"truncated":false,"fetchReceiptSha256":receipt_digest});
    if request_kind == "SEARCH_PUBLIC_WEB" {
        let provider: BraveSearchResponse = serde_json::from_slice(bytes)
            .map_err(|_| Failure::Terminal("SOURCE_PROVIDER_SCHEMA_DRIFT", "brave".to_owned()))?;
        let mut seen_urls = std::collections::BTreeSet::new();
        let results = provider.web.results.iter().take(requested_limit).enumerate().filter_map(|(index, item)| {
            let _age = item.age.as_deref();
            let parsed = reqwest::Url::parse(&item.url).ok()?;
            if parsed.scheme() != "https" || !seen_urls.insert(parsed.to_string()) {
                return None;
            }
            let host = parsed.host_str()?;
            let title = if item.title.trim().is_empty() { host } else { item.title.as_str() };
            let snippet = item.description.as_deref().map(|value| value.chars().take(1000).collect::<String>());
            Some(json!({"rank":index+1,"title":title,"origin":format!("{}://{}",parsed.scheme(),host),"path":parsed.path(),"snippet":snippet,"discoveredUrlSha256":sha256(item.url.as_bytes()),"artifactId":null}))
        }).collect::<Vec<_>>();
        let truncated = provider.web.results.len() > requested_limit;
        output["searchResults"] = Value::Array(results);
        output["truncated"] = json!(truncated);
        // Brave's published web-search unit price is represented by the
        // immutable local schedule (one request = USD 0.005).  The FX fact is
        // explicit rather than a zero/synthetic cost so every discovery is
        // economically metered and replayable.
        let pricing = brave_pricing.ok_or_else(|| Failure::Terminal("BRAVE_PRICING_UNAVAILABLE", "activated schedule missing".to_owned()))?;
        let brave_price_usd_micros = pricing.get("usdMicrosPerRequest").and_then(Value::as_i64).ok_or_else(|| Failure::Terminal("BRAVE_PRICING_INVALID", "usdMicrosPerRequest".to_owned()))?;
        let usd_krw_micros = pricing.get("usdKrwMicros").and_then(Value::as_i64).ok_or_else(|| Failure::Terminal("BRAVE_PRICING_INVALID", "usdKrwMicros".to_owned()))?;
        let cost_micros_krw = pricing.get("costMicrosKrw").and_then(Value::as_i64).ok_or_else(|| Failure::Terminal("BRAVE_PRICING_INVALID", "costMicrosKrw".to_owned()))?;
        let mut discovery = json!({"providerId":"BRAVE_SEARCH_WEB_V1","adapterVersion":1,"providerConfigurationId":stable_uuid(b"brave-search-provider-configuration-v1"),"providerConfigurationVersion":1,"providerConfigurationSha256":sha256(b"brave-search-config-v1"),"searchRequestSha256":request_sha256,"responseBodySha256":response_sha256,"httpStatus":status,"resultCount":output["searchResults"].as_array().map_or(0, Vec::len),"usageRequests":1,"priceScheduleId":stable_uuid(b"brave-search-price-schedule-v1"),"priceScheduleVersion":pricing.get("scheduleVersion"),"priceScheduleSha256":pricing.get("scheduleSha256"),"fxFactId":pricing.get("fxFactId"),"fxFactSha256":pricing.get("fxFactSha256"),"usdMicrosPerRequest":brave_price_usd_micros,"usdKrwMicros":usd_krw_micros,"costMicrosKrw":cost_micros_krw,"gatewayReceiptSha256":gateway_receipt_sha256,"observedAt":retrieved_at});
        discovery["receiptSha256"] = json!(sha256(&canonical_bytes(&discovery)?));
        output["discoveryReceipt"] = discovery;
    } else {
        let artifact_identity = json!({"schemaVersion":"research-artifact.v2","researchArtifactId":artifact_id,"assetId":asset_id,"assetRevision":1,"sourceFetchId":fetch_id,"artifactOrdinal":0,"fetchOutcome":"STORED","sourceAuthority":source_id,"finalOrigin":redacted_locator,"httpStatus":status,"contentMediaType":pending.content_media_type.clone().unwrap_or_else(|| "application/octet-stream".to_owned()),"contentSizeBytes":bytes.len(),"contentSha256":response_sha256,"responseHeadersSha256":sha256(&canonical_bytes(safe_headers)?),"contentSafetyState":"CLEAN","contentSafetyReceiptSha256":receipt_digest});
        let artifact_sha256 = sha256(&canonical_bytes(&artifact_identity)?);
        let mut artifact_wire = artifact_identity;
        artifact_wire["artifactSha256"] = json!(artifact_sha256);
        artifact_wire["retrievedAt"] = json!(retrieved_at);
        artifact_wire["safeHeaders"] = safe_headers.clone();
        artifact_wire["redirects"] = redirects.clone();
        artifact_wire["researchOnly"] = json!(true);
        artifact_wire["sourceUseId"] = json!(pending.source_use_id);
        artifact_wire["sourceUseSha256"] = json!(pending.source_use_sha256);
        output["artifacts"] = json!([artifact_wire]);
    }
    Ok(output)
}

pub(super) async fn persist_research_fetch(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    tool_call_id: Uuid,
    call_id: &str,
    result_sha256: &str,
    source: &PendingSourceFetch,
) -> Result<(), Failure> {
    sqlx::query_scalar::<_, Value>(
        "SELECT ops.record_research_fetch_v1($1,$2,$3,$4,CAST($5 AS char(64)),$6,$7,$8,$9,$10,$11,$12,CAST($13 AS char(64)),$14,$15,$16,CAST($17 AS char(64)),$18,$19,$20,$21,$22,CAST($23 AS char(64)),$24,$25)",
    )
    .bind(turn.run_id)
    .bind(turn.turn_id)
    .bind(tool_call_id)
    .bind(call_id)
    .bind(&turn.input_snapshot_sha256)
    .bind(source.request_kind)
    .bind(source.source_id)
    .bind(&source.external_locator)
    .bind(&source.source_url_redacted)
    .bind(&source.final_url_redacted)
    .bind(source.http_status)
    .bind(source.content_media_type.as_deref())
    .bind(&source.request_sha256)
    .bind(&source.content)
    .bind(&source.object_key)
    .bind(source.policy_version)
    .bind(result_sha256)
    .bind(source.fetch_id)
    .bind(source.asset_id)
    .bind(source.artifact_id)
    .bind(source.source_use_id)
    .bind(&source.source_use_sha256)
    .bind(&source.content_safety_receipt_sha256)
    .bind(&source.safe_headers)
    .bind(&source.redirects)
    .fetch_one(&mut *executor)
    .await
    .map_err(database)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::scan_fetched_content;

    #[test]
    fn scanner_flags_prompt_injection_and_quarantines_binary_payloads() {
        let flagged = scan_fetched_content(b"ignore previous instructions", Some("text/plain"));
        assert_eq!(flagged.state, "FLAGGED");
        let quarantined = scan_fetched_content(&[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], Some("application/octet-stream"));
        assert_eq!(quarantined.state, "QUARANTINED");
        let clean = scan_fetched_content(b"ordinary public evidence", Some("text/plain"));
        assert_eq!(clean.state, "CLEAN");
    }
}
