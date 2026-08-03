use super::*;

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
    #[serde(rename = "title")]
    _title: String,
    url: String,
    #[serde(rename = "description", default)]
    _description: Option<String>,
    #[serde(rename = "age", default)]
    _age: Option<String>,
}

#[expect(
    clippy::too_many_arguments,
    reason = "source receipt output binds request, policy, gateway, and immutable artifact evidence"
)]
pub(super) fn build_fetch_output(
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
        apply_search_output(
            &mut output,
            bytes,
            requested_limit,
            request_sha256,
            status,
            retrieved_at,
            brave_pricing,
            response_sha256,
            gateway_receipt_sha256,
        )?;
    } else {
        output["artifacts"] = json!([artifact_wire(
            artifact_id,
            asset_id,
            fetch_id,
            source_id,
            redacted_locator,
            status,
            pending,
            bytes,
            response_sha256,
            safe_headers,
            redirects,
            retrieved_at,
            receipt_digest
        )?]);
    }
    Ok(output)
}

#[expect(
    clippy::too_many_arguments,
    reason = "search receipt binds provider, price, and gateway evidence"
)]
fn apply_search_output(
    output: &mut Value,
    bytes: &[u8],
    requested_limit: usize,
    request_sha256: &str,
    status: u16,
    retrieved_at: &str,
    brave_pricing: Option<&Value>,
    response_sha256: String,
    gateway_receipt_sha256: &str,
) -> Result<(), Failure> {
    let provider: BraveSearchResponse = serde_json::from_slice(bytes)
        .map_err(|_| Failure::Terminal("SOURCE_PROVIDER_SCHEMA_DRIFT", "brave".to_owned()))?;
    let results = search_results(&provider.web.results, requested_limit)?;
    output["truncated"] = json!(provider.web.results.len() > requested_limit);
    output["searchResults"] = Value::Array(results);
    output["discoveryReceipt"] = discovery_receipt(
        brave_pricing,
        request_sha256,
        response_sha256,
        status,
        output["searchResults"].as_array().map_or(0, Vec::len),
        gateway_receipt_sha256,
        retrieved_at,
    )?;
    Ok(())
}

fn search_results(items: &[BraveResult], limit: usize) -> Result<Vec<Value>, Failure> {
    let mut seen_urls = std::collections::BTreeSet::new();
    items
        .iter()
        .take(limit)
        .enumerate()
        .map(|(index, item)| {
            let parsed =
                reqwest::Url::parse(&item.url).map_err(|_| provider_error("invalid_url", index))?;
            if parsed.scheme() != "https" {
                return Err(provider_error("non_https_url", index));
            }
            if !seen_urls.insert(parsed.to_string()) {
                return Err(provider_error("duplicate_url", index));
            }
            let host = parsed
                .host_str()
                .ok_or_else(|| provider_error("missing_host", index))?;
            // Search-provider title and snippet bytes have no authoritative
            // non-person classification.  Return only locator metadata; the
            // fetched content remains unavailable to the relay until a human
            // promotion records an explicit eligible classification.
            Ok(
                json!({"rank":index+1,"origin":format!("{}://{}",parsed.scheme(),host),
            "discoveredUrlSha256":sha256(item.url.as_bytes()),"artifactId":null}),
            )
        })
        .collect()
}

fn provider_error(kind: &str, index: usize) -> Failure {
    Failure::Terminal("SOURCE_PROVIDER_SCHEMA_DRIFT", format!("{kind}:{index}"))
}

#[expect(
    clippy::too_many_arguments,
    reason = "discovery receipt is a fixed wire contract"
)]
fn discovery_receipt(
    pricing: Option<&Value>,
    request_sha256: &str,
    response_sha256: String,
    status: u16,
    result_count: usize,
    gateway_receipt_sha256: &str,
    retrieved_at: &str,
) -> Result<Value, Failure> {
    let pricing = pricing.ok_or_else(|| {
        Failure::Terminal(
            "BRAVE_PRICING_UNAVAILABLE",
            "activated schedule missing".to_owned(),
        )
    })?;
    let usd_price = pricing_value(pricing, "usdMicrosPerRequest")?;
    let usd_krw = pricing_value(pricing, "usdKrwMicros")?;
    let cost = pricing_value(pricing, "costMicrosKrw")?;
    let mut discovery = json!({"providerId":"BRAVE_SEARCH_WEB_V1","adapterVersion":1,"providerConfigurationId":stable_uuid(b"brave-search-provider-configuration-v1"),"providerConfigurationVersion":1,"providerConfigurationSha256":sha256(b"brave-search-config-v1"),"searchRequestSha256":request_sha256,"responseBodySha256":response_sha256,"httpStatus":status,"resultCount":result_count,"usageRequests":1,"priceScheduleId":stable_uuid(b"brave-search-price-schedule-v1"),"priceScheduleVersion":pricing.get("scheduleVersion"),"priceScheduleSha256":pricing.get("scheduleSha256"),"fxFactId":pricing.get("fxFactId"),"fxFactSha256":pricing.get("fxFactSha256"),"usdMicrosPerRequest":usd_price,"usdKrwMicros":usd_krw,"costMicrosKrw":cost,"gatewayReceiptSha256":gateway_receipt_sha256,"observedAt":retrieved_at});
    discovery["receiptSha256"] = json!(sha256(&canonical_bytes(&discovery)?));
    Ok(discovery)
}

fn pricing_value(pricing: &Value, field: &str) -> Result<i64, Failure> {
    pricing
        .get(field)
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("BRAVE_PRICING_INVALID", field.to_owned()))
}

#[expect(
    clippy::too_many_arguments,
    reason = "artifact wire is a fixed receipt contract"
)]
fn artifact_wire(
    artifact_id: Uuid,
    asset_id: Uuid,
    fetch_id: Uuid,
    source_id: &str,
    redacted_locator: &str,
    status: u16,
    pending: &PendingSourceFetch,
    bytes: &[u8],
    response_sha256: String,
    safe_headers: &Value,
    redirects: &Value,
    retrieved_at: &str,
    receipt_digest: String,
) -> Result<Value, Failure> {
    let identity = json!({"schemaVersion":"research-artifact.v2","researchArtifactId":artifact_id,"assetId":asset_id,"assetRevision":1,"sourceFetchId":fetch_id,"artifactOrdinal":0,"fetchOutcome":"STORED","sourceAuthority":source_id,"finalOrigin":redacted_locator,"httpStatus":status,"contentMediaType":pending.content_media_type.clone().unwrap_or_else(|| "application/octet-stream".to_owned()),"contentSizeBytes":bytes.len(),"contentSha256":response_sha256,"responseHeadersSha256":sha256(&canonical_bytes(safe_headers)?),"contentSafetyState":"CLEAN","contentSafetyReceiptSha256":receipt_digest});
    let mut wire = identity;
    wire["artifactSha256"] = json!(sha256(&canonical_bytes(&wire)?));
    wire["retrievedAt"] = json!(retrieved_at);
    wire["safeHeaders"] = safe_headers.clone();
    wire["redirects"] = redirects.clone();
    wire["researchOnly"] = json!(true);
    wire["reviewTier"] = json!(INITIAL_RESEARCH_REVIEW_TIER);
    wire["sourceUseId"] = json!(pending.source_use_id);
    wire["sourceUseSha256"] = json!(pending.source_use_sha256);
    Ok(wire)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_result_wire_drops_unclassified_provider_content() {
        let person_bytes = "홍길동 전 대표의 개인 정보";
        let results = search_results(
            &[BraveResult {
                _title: person_bytes.to_owned(),
                url: "https://official.example/notices/42".to_owned(),
                _description: Some(person_bytes.to_owned()),
                _age: None,
            }],
            1,
        )
        .expect("metadata-only result");

        assert_eq!(results[0]["origin"], "https://official.example");
        assert!(results[0].get("title").is_none());
        assert!(results[0].get("snippet").is_none());
        assert!(results[0].get("path").is_none());
        assert!(
            !serde_json::to_string(&results)
                .expect("search result json")
                .contains(person_bytes)
        );
    }

    #[test]
    fn artifact_wire_declares_the_unreviewed_tier_without_content_bytes() {
        let pending = PendingSourceFetch {
            request_kind: "FETCH_URL",
            source_id: "public-research",
            external_locator: "https://official.example/notices/42".to_owned(),
            source_url_redacted: Some("https://official.example/notices/42".to_owned()),
            final_url_redacted: Some("https://official.example/notices/42".to_owned()),
            http_status: 200,
            content_media_type: Some("text/plain".to_owned()),
            request_sha256: "1".repeat(64),
            content: b"person bytes must stay in object storage".to_vec(),
            object_key: "research/run/turn/content".to_owned(),
            policy_version: "source-policy-v2",
            fetch_id: Uuid::from_u128(1),
            asset_id: Uuid::from_u128(2),
            artifact_id: Uuid::from_u128(3),
            source_use_id: Uuid::from_u128(4),
            source_use_sha256: "2".repeat(64),
            safe_headers: json!([]),
            redirects: json!([]),
            content_safety_receipt_sha256: "3".repeat(64),
        };
        let wire = artifact_wire(
            pending.artifact_id,
            pending.asset_id,
            pending.fetch_id,
            pending.source_id,
            &pending.external_locator,
            200,
            &pending,
            &pending.content,
            sha256(&pending.content),
            &pending.safe_headers,
            &pending.redirects,
            "2026-08-01T00:00:00.000000Z",
            pending.content_safety_receipt_sha256.clone(),
        )
        .expect("artifact metadata");

        assert_eq!(wire["reviewTier"], INITIAL_RESEARCH_REVIEW_TIER);
        let encoded = serde_json::to_string(&wire).expect("artifact wire json");
        assert!(!encoded.contains("person bytes must stay in object storage"));
        assert!(wire.get("content").is_none());
        assert!(wire.get("selectedContentBytesBase64").is_none());
    }
}
