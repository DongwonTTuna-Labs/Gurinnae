use serde::{Deserialize, Serialize};
use uuid::Uuid;

fn deserialize_official_unreviewed<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    if value == "OFFICIAL_UNREVIEWED" {
        Ok(value)
    } else {
        Err(serde::de::Error::custom(
            "a fresh source.fetch artifact must be OFFICIAL_UNREVIEWED",
        ))
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct LocatorVerification {
    pub valid: bool,
    pub actual_selected_content_sha256: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SourceLocatorVerifyResponse {
    pub verification: LocatorVerification,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceFetchResponseV2 {
    #[serde(rename = "schemaVersion")]
    pub schema_version: String,
    #[serde(rename = "requestKind")]
    pub request_kind: String,
    #[serde(rename = "gatewayDecision")]
    pub gateway_decision: GatewayDecisionV2,
    #[serde(rename = "discoveryReceipt")]
    pub discovery_receipt: Option<DiscoveryReceiptV2>,
    #[serde(rename = "searchResults")]
    pub search_results: Vec<SearchResultV2>,
    pub artifacts: Vec<SourceArtifactV2>,
    pub truncated: bool,
    #[serde(rename = "fetchReceiptSha256")]
    pub fetch_receipt_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GatewayDecisionV2 {
    #[serde(rename = "policyVersion")]
    pub policy_version: String,
    #[serde(rename = "policySha256")]
    pub policy_sha256: String,
    pub decision: String,
    #[serde(rename = "decisionCode")]
    pub decision_code: String,
    #[serde(rename = "decisionSha256")]
    pub decision_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiscoveryReceiptV2 {
    #[serde(rename = "providerId")]
    pub provider_id: String,
    #[serde(rename = "adapterVersion")]
    pub adapter_version: u8,
    #[serde(rename = "providerConfigurationId")]
    pub provider_configuration_id: Uuid,
    #[serde(rename = "providerConfigurationVersion")]
    pub provider_configuration_version: u64,
    #[serde(rename = "providerConfigurationSha256")]
    pub provider_configuration_sha256: String,
    #[serde(rename = "searchRequestSha256")]
    pub search_request_sha256: String,
    #[serde(rename = "responseBodySha256")]
    pub response_body_sha256: String,
    #[serde(rename = "httpStatus")]
    pub http_status: u16,
    #[serde(rename = "resultCount")]
    pub result_count: u8,
    #[serde(rename = "usageRequests")]
    pub usage_requests: u8,
    #[serde(rename = "priceScheduleId")]
    pub price_schedule_id: Uuid,
    #[serde(rename = "priceScheduleVersion")]
    pub price_schedule_version: u64,
    #[serde(rename = "priceScheduleSha256")]
    pub price_schedule_sha256: String,
    #[serde(rename = "fxFactId")]
    pub fx_fact_id: Uuid,
    #[serde(rename = "fxFactSha256")]
    pub fx_fact_sha256: String,
    #[serde(rename = "costMicrosKrw")]
    pub cost_micros_krw: u64,
    #[serde(rename = "gatewayReceiptSha256")]
    pub gateway_receipt_sha256: String,
    #[serde(rename = "observedAt")]
    pub observed_at: String,
    #[serde(rename = "receiptSha256")]
    pub receipt_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SearchResultV2 {
    pub rank: u8,
    pub origin: String,
    #[serde(rename = "discoveredUrlSha256")]
    pub discovered_url_sha256: String,
    #[serde(rename = "artifactId")]
    pub artifact_id: Option<Uuid>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceArtifactV2 {
    #[serde(rename = "researchArtifactId")]
    pub research_artifact_id: Uuid,
    #[serde(rename = "assetId")]
    pub asset_id: Uuid,
    #[serde(rename = "assetRevision")]
    pub asset_revision: u8,
    #[serde(rename = "sourceFetchId")]
    pub source_fetch_id: Uuid,
    #[serde(rename = "artifactOrdinal")]
    pub artifact_ordinal: u8,
    #[serde(rename = "fetchOutcome")]
    pub fetch_outcome: String,
    #[serde(rename = "sourceAuthority")]
    pub source_authority: String,
    #[serde(rename = "finalOrigin")]
    pub final_origin: String,
    #[serde(rename = "retrievedAt")]
    pub retrieved_at: String,
    #[serde(rename = "httpStatus")]
    pub http_status: u16,
    #[serde(rename = "contentMediaType")]
    pub content_media_type: String,
    #[serde(rename = "contentSizeBytes")]
    pub content_size_bytes: u64,
    #[serde(rename = "contentSha256")]
    pub content_sha256: String,
    #[serde(rename = "artifactSha256")]
    pub artifact_sha256: String,
    #[serde(rename = "responseHeadersSha256")]
    pub response_headers_sha256: String,
    #[serde(rename = "safeHeaders")]
    pub safe_headers: Vec<serde_json::Value>,
    pub redirects: Vec<serde_json::Value>,
    #[serde(rename = "contentSafetyState")]
    pub content_safety_state: String,
    #[serde(rename = "contentSafetyReceiptSha256")]
    pub content_safety_receipt_sha256: String,
    #[serde(rename = "researchOnly")]
    pub research_only: bool,
    #[serde(
        rename = "reviewTier",
        deserialize_with = "deserialize_official_unreviewed"
    )]
    pub review_tier: String,
    #[serde(rename = "sourceUseId")]
    pub source_use_id: Uuid,
    #[serde(rename = "sourceUseSha256")]
    pub source_use_sha256: String,
}

#[cfg(test)]
mod tests {
    use super::{SearchResultV2, SourceArtifactV2};
    use serde_json::json;

    fn artifact(review_tier: &str) -> serde_json::Value {
        json!({
            "researchArtifactId": "00000000-0000-0000-0000-000000000001",
            "assetId": "00000000-0000-0000-0000-000000000002",
            "assetRevision": 1,
            "sourceFetchId": "00000000-0000-0000-0000-000000000003",
            "artifactOrdinal": 0,
            "fetchOutcome": "STORED",
            "sourceAuthority": "public-research",
            "finalOrigin": "https://official.example/notices/42",
            "retrievedAt": "2026-08-01T00:00:00Z",
            "httpStatus": 200,
            "contentMediaType": "text/plain",
            "contentSizeBytes": 42,
            "contentSha256": "1".repeat(64),
            "artifactSha256": "2".repeat(64),
            "responseHeadersSha256": "3".repeat(64),
            "safeHeaders": [],
            "redirects": [],
            "contentSafetyState": "CLEAN",
            "contentSafetyReceiptSha256": "4".repeat(64),
            "researchOnly": true,
            "reviewTier": review_tier,
            "sourceUseId": "00000000-0000-0000-0000-000000000004",
            "sourceUseSha256": "5".repeat(64)
        })
    }

    #[test]
    fn source_fetch_artifact_review_tier_is_closed_and_round_trips() {
        let parsed: SourceArtifactV2 =
            serde_json::from_value(artifact("OFFICIAL_UNREVIEWED")).expect("fresh artifact tier");
        assert_eq!(parsed.review_tier, "OFFICIAL_UNREVIEWED");
        assert_eq!(
            serde_json::to_value(parsed).expect("artifact wire")["reviewTier"],
            "OFFICIAL_UNREVIEWED"
        );
        assert!(serde_json::from_value::<SourceArtifactV2>(artifact("HUMAN_PROMOTED")).is_err());
    }

    #[test]
    fn search_result_rejects_unclassified_provider_text() {
        let result = json!({
            "rank": 1,
            "origin": "https://official.example",
            "discoveredUrlSha256": "6".repeat(64),
            "artifactId": null
        });
        assert!(serde_json::from_value::<SearchResultV2>(result.clone()).is_ok());
        for field in ["title", "snippet", "path"] {
            let mut leaked = result.clone();
            leaked[field] = json!("홍길동 개인 정보");
            assert!(serde_json::from_value::<SearchResultV2>(leaked).is_err());
        }
    }
}
