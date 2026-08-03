//! Typed agent runtime boundary.
//!
//! The provider and database adapters are intentionally expressed in closed
//! Rust enums.  A request for one tool cannot be decoded as another tool's
//! request and an adapter response is checked against the same tool before it
//! can extend a transcript.  This module contains no provider payload storage
//! and never accepts a generic JSON object as an agent result.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[path = "runtime_adapters.rs"]
mod adapters;
#[path = "runtime_control.rs"]
mod control;
#[path = "runtime_dispatch.rs"]
mod dispatch;
#[path = "runtime_relationship.rs"]
mod relationship;
#[path = "runtime_source.rs"]
mod source;
#[path = "runtime_turn.rs"]
mod turn;

pub use adapters::{
    AgencyProfileRecord, ComparableRecord, ContractCorpusRecord, EntityRecord, EvidenceRecord,
    RelationshipEndpointRecordV3, RelationshipNeighborRecord, RelationshipNeighborRecordV3,
    ResponseRecord, RuleRecord, SourceArtifactRecord, SupplierProfileRecord, ToolSnapshot,
};
pub use control::{
    CancelReason, ControlReceipt, ControlState, ProofKind, ReconciliationProof, RunControl,
    RunStatus, RuntimeError,
};
pub use dispatch::{DispatchError, ToolAdapter, TypedDispatcher};
pub use relationship::{
    RelationshipEndpointKindV3, RelationshipEndpointSelectorV3, RelationshipEndpointV3,
    RelationshipKindV3, RelationshipNeighborV3, RelationshipNeighborsRequestV3,
    RelationshipNeighborsResponseV3,
};
pub use source::{
    DiscoveryReceiptV2, GatewayDecisionV2, LocatorVerification, SearchResultV2, SourceArtifactV2,
    SourceFetchResponseV2, SourceLocatorVerifyResponse,
};
pub use turn::{
    AgentFinalOutput, Citation, FinalStatus, MultiTurnConfig, MultiTurnRuntime, ProviderAdapter,
    ProviderEnvelope, ProviderOutcome, ProviderReceipt, ProviderReply, ProviderRequest,
    ProviderRuntimeError, ProviderTurn, RunOutcome, ToolCall, ToolResult, Transcript,
    provider_receipt_sha256, provider_request_sha256,
};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolId {
    AgencyProfile,
    ClaimLanguageCheck,
    ContractSearch,
    ContractFindComparables,
    EntityLookup,
    EvidenceRead,
    EvidenceSearch,
    RelationshipNeighbors,
    ResponseRead,
    RuleReproduce,
    SourceFetch,
    SourceLocatorVerify,
    SupplierProfile,
}

pub(super) fn digest_without_digest<T: Serialize>(value: &T) -> Result<String, RuntimeError> {
    serde_json::to_vec(value)
        .map(|bytes| {
            Sha256::digest(bytes)
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect()
        })
        .map_err(|_| RuntimeError::Serialization)
}

pub(super) fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Media types that the source-fetch pipeline can persist and hand to the
/// authority parsers.  Keeping this list closed prevents a provider from
/// widening the egress contract to arbitrary binary content while allowing
/// HTML, office/PDF documents, images, audio and video in one typed request.
pub const SOURCE_FETCH_MEDIA_TYPES: &[&str] = &[
    "text/html",
    "text/plain",
    "text/csv",
    "application/json",
    "application/xml",
    "application/pdf",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/hwp+zip",
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/tiff",
    "audio/wav",
    "video/webm",
];

#[cfg(test)]
#[path = "tests.rs"]
mod tests;

impl ToolId {
    pub const ALL: [Self; 13] = [
        Self::AgencyProfile,
        Self::ClaimLanguageCheck,
        Self::ContractSearch,
        Self::ContractFindComparables,
        Self::EntityLookup,
        Self::EvidenceRead,
        Self::EvidenceSearch,
        Self::RelationshipNeighbors,
        Self::ResponseRead,
        Self::RuleReproduce,
        Self::SourceFetch,
        Self::SourceLocatorVerify,
        Self::SupplierProfile,
    ];

    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::AgencyProfile => "agency.profile",
            Self::ClaimLanguageCheck => "claim.language_check",
            Self::ContractSearch => "contract.search",
            Self::ContractFindComparables => "contract.find_comparables",
            Self::EntityLookup => "entity.lookup",
            Self::EvidenceRead => "evidence.read",
            Self::EvidenceSearch => "evidence.search",
            Self::RelationshipNeighbors => "relationship.neighbors",
            Self::ResponseRead => "response.read",
            Self::RuleReproduce => "rule.reproduce",
            Self::SourceFetch => "source.fetch",
            Self::SourceLocatorVerify => "source.locator_verify",
            Self::SupplierProfile => "supplier.profile",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SnapshotBinding {
    pub run_id: Uuid,
    pub input_snapshot_id: Uuid,
    pub input_snapshot_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ClaimLanguageCheckRequest {
    pub binding: SnapshotBinding,
    pub draft_text: String,
    pub draft_text_sha256: String,
    pub claim_type: ClaimType,
    pub locale: ClaimLocale,
    pub allowed_citation_ids: Vec<Uuid>,
    pub language_policy_version: String,
    pub language_policy_sha256: String,
    pub max_findings: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ClaimType {
    Fact,
    Calculation,
    Inference,
    Limitation,
    OfficialOutcome,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ClaimLocale {
    #[serde(rename = "ko-KR")]
    KoKr,
    #[serde(rename = "en-US")]
    EnUs,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ContractSearchRequest {
    pub binding: SnapshotBinding,
    pub entity_kind: ContractEntityKind,
    pub entity_id: Option<Uuid>,
    pub from_date: Option<String>,
    pub to_date: Option<String>,
    pub procurement_methods: Vec<String>,
    pub limit: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ContractEntityKind {
    Any,
    Agency,
    Supplier,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SupplierProfileRequest {
    pub binding: SnapshotBinding,
    pub supplier_id: Uuid,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgencyProfileRequest {
    pub binding: SnapshotBinding,
    pub agency_id: Uuid,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RelationshipNeighborsRequest {
    pub binding: SnapshotBinding,
    pub supplier_id: Uuid,
    pub relationship_kinds: Vec<RelationshipKind>,
    pub as_of: Option<String>,
    pub limit: u8,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RelationshipKind {
    Ownership,
    BeneficialOwnership,
    Control,
    ManagementRole,
    LegalRepresentative,
    ContractualRelationship,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ContractFindComparablesRequest {
    pub binding: SnapshotBinding,
    pub subject_contract_id: Uuid,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EntityLookupRequest {
    pub binding: SnapshotBinding,
    pub entity_kind: EntityKind,
    pub identifiers: Vec<EntityIdentifier>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EvidenceReadRequest {
    pub binding: SnapshotBinding,
    pub evidence_id: Uuid,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EvidenceSearchRequest {
    pub binding: SnapshotBinding,
    pub query: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ResponseReadRequest {
    pub binding: SnapshotBinding,
    pub response_id: Uuid,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RuleReproduceRequest {
    pub binding: SnapshotBinding,
    pub rule_version_id: Uuid,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SourceFetchRequest {
    pub binding: SnapshotBinding,
    pub request_kind: SourceRequestKind,
    /// SEARCH_PUBLIC_WEB carries a query and closed discovery parameters. The
    /// legacy request remains source-compatible by defaulting these fields;
    /// production V2 conversion rejects an empty query instead of silently
    /// turning discovery into a no-op.
    #[serde(default)]
    pub query: Option<String>,
    #[serde(default)]
    pub locale: Option<String>,
    #[serde(default)]
    pub country: Option<String>,
    #[serde(default)]
    pub recency_days: Option<u16>,
    #[serde(default)]
    pub result_limit: Option<u8>,
    pub canonical_url: Option<String>,
}

/// Canonical V2 egress request.  The legacy snapshot adapter above remains a
/// database-facing seam, while provider transport must use this closed
/// schema so policy, rights purpose and byte limits cannot be omitted.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SourceFetchRequestV2 {
    SearchPublicWeb {
        #[serde(rename = "schemaVersion")]
        schema_version: String,
        #[serde(rename = "runId")]
        run_id: Uuid,
        #[serde(rename = "inputSnapshotId")]
        input_snapshot_id: Uuid,
        #[serde(rename = "inputSnapshotSha256")]
        input_snapshot_sha256: String,
        #[serde(rename = "requestKind")]
        request_kind: String,
        query: String,
        locale: String,
        country: String,
        #[serde(rename = "recencyDays")]
        recency_days: Option<u16>,
        #[serde(rename = "resultLimit")]
        result_limit: u8,
        #[serde(rename = "sourcePolicyVersion")]
        source_policy_version: String,
        #[serde(rename = "sourcePolicySha256")]
        source_policy_sha256: String,
        #[serde(rename = "rightsPurpose")]
        rights_purpose: String,
        #[serde(rename = "maxBytesPerArtifact")]
        max_bytes_per_artifact: u64,
    },
    FetchUrl {
        #[serde(rename = "schemaVersion")]
        schema_version: String,
        #[serde(rename = "runId")]
        run_id: Uuid,
        #[serde(rename = "inputSnapshotId")]
        input_snapshot_id: Uuid,
        #[serde(rename = "inputSnapshotSha256")]
        input_snapshot_sha256: String,
        #[serde(rename = "requestKind")]
        request_kind: String,
        url: String,
        #[serde(rename = "expectedMediaTypes")]
        expected_media_types: Vec<String>,
        #[serde(rename = "sourcePolicyVersion")]
        source_policy_version: String,
        #[serde(rename = "sourcePolicySha256")]
        source_policy_sha256: String,
        #[serde(rename = "rightsPurpose")]
        rights_purpose: String,
        #[serde(rename = "maxBytes")]
        max_bytes: u64,
        #[serde(rename = "allowRedirects")]
        allow_redirects: bool,
    },
}

impl SourceFetchRequest {
    pub fn to_v2(&self) -> Result<SourceFetchRequestV2, RuntimeError> {
        let policy = "source-policy-v2".to_owned();
        let policy_sha = sha256_hex(policy.as_bytes());
        match self.request_kind {
            SourceRequestKind::SearchPublicWeb => {
                let query = self
                    .query
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .ok_or(RuntimeError::InvalidTransition)?;
                let locale = self.locale.clone().unwrap_or_else(|| "ko-KR".to_owned());
                let country = self.country.clone().unwrap_or_else(|| "KR".to_owned());
                let result_limit = self.result_limit.unwrap_or(10);
                if result_limit == 0
                    || result_limit > 20
                    || query.len() > 1000
                    || !locale
                        .as_bytes()
                        .get(0..2)
                        .is_some_and(|v| v.iter().all(u8::is_ascii_lowercase))
                    || locale.as_bytes().get(2) != Some(&b'-')
                    || !locale
                        .as_bytes()
                        .get(3..5)
                        .is_some_and(|v| v.iter().all(u8::is_ascii_uppercase))
                    || country.len() != 2
                    || !country.bytes().all(|byte| byte.is_ascii_uppercase())
                {
                    return Err(RuntimeError::InvalidTransition);
                }
                Ok(SourceFetchRequestV2::SearchPublicWeb {
                    schema_version: "source.fetch.request.v2".to_owned(),
                    run_id: self.binding.run_id,
                    input_snapshot_id: self.binding.input_snapshot_id,
                    input_snapshot_sha256: self.binding.input_snapshot_sha256.clone(),
                    request_kind: "SEARCH_PUBLIC_WEB".to_owned(),
                    query: query.to_owned(),
                    locale,
                    country,
                    recency_days: self.recency_days,
                    result_limit,
                    source_policy_version: policy,
                    source_policy_sha256: policy_sha,
                    rights_purpose: "FACT_CHECK".to_owned(),
                    max_bytes_per_artifact: 26_214_400,
                })
            }
            SourceRequestKind::FetchUrl => {
                let url = self
                    .canonical_url
                    .clone()
                    .ok_or(RuntimeError::InvalidTransition)?;
                let parsed = url::Url::parse(&url).map_err(|_| RuntimeError::InvalidTransition)?;
                if parsed.scheme() != "https" || url.len() > 2048 || parsed.host_str().is_none() {
                    return Err(RuntimeError::InvalidTransition);
                }
                Ok(SourceFetchRequestV2::FetchUrl {
                    schema_version: "source.fetch.request.v2".to_owned(),
                    run_id: self.binding.run_id,
                    input_snapshot_id: self.binding.input_snapshot_id,
                    input_snapshot_sha256: self.binding.input_snapshot_sha256.clone(),
                    request_kind: "FETCH_URL".to_owned(),
                    url,
                    expected_media_types: SOURCE_FETCH_MEDIA_TYPES
                        .iter()
                        .map(|value| (*value).to_owned())
                        .collect(),
                    source_policy_version: policy,
                    source_policy_sha256: policy_sha,
                    rights_purpose: "FACT_CHECK".to_owned(),
                    max_bytes: 26_214_400,
                    allow_redirects: false,
                })
            }
        }
    }

    /// Convert the flat provider V2 wire request into the persistence-facing
    /// request only after validating its closed policy fields. The network
    /// adapter calls `to_v2()` again, so omitted or altered policy values can
    /// never be silently accepted.
    pub fn from_v2(
        value: SourceFetchRequestV2,
        binding: SnapshotBinding,
    ) -> Result<Self, RuntimeError> {
        match value {
            SourceFetchRequestV2::SearchPublicWeb {
                schema_version,
                request_kind,
                query,
                locale,
                country,
                recency_days,
                result_limit,
                source_policy_version,
                source_policy_sha256,
                rights_purpose,
                max_bytes_per_artifact,
                ..
            } if schema_version == "source.fetch.request.v2"
                && request_kind == "SEARCH_PUBLIC_WEB"
                && source_policy_version == "source-policy-v2"
                && source_policy_sha256 == sha256_hex(b"source-policy-v2")
                && rights_purpose == "FACT_CHECK"
                && max_bytes_per_artifact == 26_214_400 =>
            {
                Ok(Self {
                    binding,
                    request_kind: SourceRequestKind::SearchPublicWeb,
                    query: Some(query),
                    locale: Some(locale),
                    country: Some(country),
                    recency_days,
                    result_limit: Some(result_limit),
                    canonical_url: None,
                })
            }
            SourceFetchRequestV2::FetchUrl {
                schema_version,
                request_kind,
                url,
                expected_media_types,
                source_policy_version,
                source_policy_sha256,
                rights_purpose,
                max_bytes,
                allow_redirects,
                ..
            } if schema_version == "source.fetch.request.v2"
                && request_kind == "FETCH_URL"
                && expected_media_types
                    == SOURCE_FETCH_MEDIA_TYPES
                        .iter()
                        .map(|value| (*value).to_owned())
                        .collect::<Vec<_>>()
                && source_policy_version == "source-policy-v2"
                && source_policy_sha256 == sha256_hex(b"source-policy-v2")
                && rights_purpose == "FACT_CHECK"
                && max_bytes == 26_214_400
                && !allow_redirects =>
            {
                Ok(Self {
                    binding,
                    request_kind: SourceRequestKind::FetchUrl,
                    query: None,
                    locale: None,
                    country: None,
                    recency_days: None,
                    result_limit: None,
                    canonical_url: Some(url),
                })
            }
            _ => Err(RuntimeError::InvalidTransition),
        }
    }
}

#[path = "runtime_legacy.rs"]
mod legacy;
pub use legacy::{
    AgencyProfile, AgencyProfileResponse, Comparable, ComparablesResponse, ContractSearchHit,
    ContractSearchResponse, EntityIdentifier, EntityIdentifierKind, EntityKind,
    EntityLookupResponse, EntityMatch, EvidenceHit, EvidenceReadResponse, EvidenceSearchResponse,
    EvidenceValue, Finding, LanguageCheckResponse, LanguageDecision, LanguageFindingCode,
    LanguageFindingSeverity, RelationshipNeighbor, RelationshipNeighborsResponse,
    ReproductionValue, ResponseReadResponse, ResponseValue, RuleReproduceResponse, SourceArtifact,
    SourceFetchResponse, SourceLocatorVerifyRequest, SourceRequestKind, SupplierIdentityStatus,
    SupplierProfile, SupplierProfileResponse, ToolRequest, ToolResponse,
};
