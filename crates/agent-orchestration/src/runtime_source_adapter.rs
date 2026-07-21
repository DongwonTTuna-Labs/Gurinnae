use super::*;

pub(super) fn fetch(
    adapter: &SnapshotAdapter,
    value: &SourceFetchRequest,
) -> Result<ToolResponse, DispatchError> {
    match value.request_kind {
        SourceRequestKind::SearchPublicWeb => fetch_search(adapter, value),
        SourceRequestKind::FetchUrl => fetch_url(adapter, value),
    }
}

fn fetch_search(
    adapter: &SnapshotAdapter,
    value: &SourceFetchRequest,
) -> Result<ToolResponse, DispatchError> {
    if value.canonical_url.is_some() {
        return Err(DispatchError::RequestInvalid);
    }
    let results = adapter
        .snapshot
        .source_artifacts
        .iter()
        .filter(|item| item.request_kind == SourceRequestKind::SearchPublicWeb)
        .enumerate()
        .filter_map(|(index, item)| {
            let url = item.final_url.as_deref().or(item.source_url.as_deref())?;
            let parsed = url::Url::parse(url).ok()?;
            Some(SearchResultV2 {
                rank: u8::try_from(index + 1).ok()?,
                title: parsed.host_str()?.to_owned(),
                origin: format!("{}://{}", parsed.scheme(), parsed.host_str()?),
                path: parsed.path().to_owned(),
                snippet: None,
                discovered_url_sha256: digest(url.as_bytes()),
                artifact_id: None,
            })
        })
        .take(20)
        .collect::<Vec<_>>();
    let result_digest =
        digest(&serde_json::to_vec(&results).map_err(|_| DispatchError::RequestInvalid)?);
    let response_body_sha256 = adapter
        .snapshot
        .source_artifacts
        .iter()
        .filter(|item| item.request_kind == SourceRequestKind::SearchPublicWeb)
        .filter_map(|item| item.content_bytes.as_deref())
        .next()
        .map(digest)
        .unwrap_or_else(|| result_digest.clone());
    let discovery = build_discovery_receipt(value, &results, response_body_sha256)?;
    Ok(ToolResponse::SourceFetch(SourceFetchResponseV2 {
        schema_version: "source.fetch.response.v2".to_owned(),
        request_kind: "SEARCH_PUBLIC_WEB".to_owned(),
        gateway_decision: gateway_decision("ALLOW", "SNAPSHOT_DISCOVERY", "source-policy-v2"),
        discovery_receipt: Some(discovery),
        search_results: results,
        artifacts: Vec::new(),
        truncated: false,
        fetch_receipt_sha256: result_digest,
    }))
}

fn build_discovery_receipt(
    value: &SourceFetchRequest,
    results: &[SearchResultV2],
    response_body_sha256: String,
) -> Result<DiscoveryReceiptV2, DispatchError> {
    let search_request_sha256 =
        digest(&serde_json::to_vec(value).map_err(|_| DispatchError::RequestInvalid)?);
    let gateway_receipt_sha256 =
        digest(format!("gateway:200:{response_body_sha256}:source-policy-v2").as_bytes());
    let mut receipt = DiscoveryReceiptV2 {
        provider_id: "BRAVE_SEARCH_WEB_V1".to_owned(),
        adapter_version: 1,
        provider_configuration_id: deterministic_uuid(b"brave-search-provider-configuration-v1"),
        provider_configuration_version: 1,
        provider_configuration_sha256: digest(b"brave-search-config-v1"),
        search_request_sha256,
        response_body_sha256,
        http_status: 200,
        result_count: u8::try_from(results.len()).map_err(|_| DispatchError::RequestInvalid)?,
        usage_requests: 1,
        price_schedule_id: deterministic_uuid(b"brave-search-price-schedule-v1"),
        price_schedule_version: 1,
        price_schedule_sha256: digest(b"brave-search-usd-micros:5000"),
        fx_fact_id: deterministic_uuid(b"usd-krw-fx-fact-2026-07-19"),
        fx_fact_sha256: digest(b"usd-krw-micros:1400000000"),
        cost_micros_krw: 7_000_000,
        gateway_receipt_sha256,
        observed_at: now_rfc3339()?,
        receipt_sha256: String::new(),
    };
    receipt.receipt_sha256 =
        digest(&serde_json::to_vec(&receipt).map_err(|_| DispatchError::RequestInvalid)?);
    Ok(receipt)
}

fn deterministic_uuid(seed: &[u8]) -> Uuid {
    let digest = sha2::Sha256::digest(seed);
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

fn fetch_url(
    adapter: &SnapshotAdapter,
    value: &SourceFetchRequest,
) -> Result<ToolResponse, DispatchError> {
    let requested = value
        .canonical_url
        .as_deref()
        .filter(|url| !url.is_empty())
        .ok_or(DispatchError::RequestInvalid)?;
    let selected = adapter
        .snapshot
        .source_artifacts
        .iter()
        .filter(|item| item.request_kind == SourceRequestKind::FetchUrl)
        .filter(|item| {
            item.final_url.as_deref() == Some(requested)
                || item.source_url.as_deref() == Some(requested)
        })
        .collect::<Vec<_>>();
    if selected.is_empty() || selected.iter().any(|item| item.content_bytes.is_none()) {
        return Err(DispatchError::RequestInvalid);
    }
    let source_fetch_id = selected
        .first()
        .map(|item| item.research_artifact_id)
        .ok_or(DispatchError::RequestInvalid)?;
    let mut receipt_bytes = Vec::new();
    let mut artifacts = Vec::with_capacity(selected.len());
    for item in selected {
        let bytes = item
            .content_bytes
            .as_deref()
            .ok_or(DispatchError::RequestInvalid)?;
        if digest(bytes) != item.content_sha256 {
            return Err(DispatchError::RequestInvalid);
        }
        receipt_bytes.extend_from_slice(bytes);
        artifacts.push(SourceArtifactV2 {
            research_artifact_id: item.research_artifact_id,
            asset_id: item.research_artifact_id,
            asset_revision: 1,
            source_fetch_id,
            artifact_ordinal: u8::try_from(artifacts.len())
                .map_err(|_| DispatchError::RequestInvalid)?,
            fetch_outcome: "STORED".to_owned(),
            source_authority: "PUBLIC_RESEARCH".to_owned(),
            final_origin: requested.to_owned(),
            retrieved_at: now_rfc3339()?,
            http_status: 200,
            content_media_type: item.content_media_type.clone(),
            content_size_bytes: u64::try_from(bytes.len()).unwrap_or(0),
            content_sha256: item.content_sha256.clone(),
            artifact_sha256: item.fetch_receipt_sha256.clone(),
            response_headers_sha256: digest(b"{}"),
            safe_headers: Vec::new(),
            redirects: Vec::new(),
            content_safety_state: "CLEAN".to_owned(),
            content_safety_receipt_sha256: digest(b"content-safety-v1"),
            research_only: true,
            source_use_id: item.source_use_id,
            source_use_sha256: digest(item.source_use_id.as_bytes()),
        });
    }
    Ok(ToolResponse::SourceFetch(SourceFetchResponseV2 {
        schema_version: "source.fetch.response.v2".to_owned(),
        request_kind: "FETCH_URL".to_owned(),
        gateway_decision: gateway_decision("ALLOW", "SNAPSHOT_ARTIFACT", "source-policy-v2"),
        discovery_receipt: None,
        search_results: Vec::new(),
        artifacts,
        truncated: false,
        fetch_receipt_sha256: digest(&receipt_bytes),
    }))
}

fn now_rfc3339() -> Result<String, DispatchError> {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|_| DispatchError::RequestInvalid)
}
