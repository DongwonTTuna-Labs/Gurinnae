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
#[path = "runtime_turn.rs"]
mod turn;

pub use adapters::{
    ComparableRecord, EntityRecord, EvidenceRecord, ResponseRecord, RuleRecord,
    SourceArtifactRecord, ToolSnapshot,
};
pub use control::{
    CancelReason, ControlReceipt, ControlState, ProofKind, ReconciliationProof, RunControl,
    RunStatus, RuntimeError,
};
pub use dispatch::{DispatchError, ToolAdapter, TypedDispatcher};
pub use turn::{
    AgentFinalOutput, Citation, FinalStatus, MultiTurnConfig, MultiTurnRuntime, ProviderAdapter,
    ProviderEnvelope, ProviderOutcome, ProviderReceipt, ProviderReply, ProviderRequest,
    ProviderRuntimeError, ProviderTurn, RunOutcome, ToolCall, ToolResult, Transcript,
    provider_receipt_sha256, provider_request_sha256,
};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolId {
    ClaimLanguageCheck,
    ContractFindComparables,
    EntityLookup,
    EvidenceRead,
    EvidenceSearch,
    ResponseRead,
    RuleReproduce,
    SourceFetch,
    SourceLocatorVerify,
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

#[cfg(test)]
#[path = "tests.rs"]
mod tests;

impl ToolId {
    pub const ALL: [Self; 9] = [
        Self::ClaimLanguageCheck,
        Self::ContractFindComparables,
        Self::EntityLookup,
        Self::EvidenceRead,
        Self::EvidenceSearch,
        Self::ResponseRead,
        Self::RuleReproduce,
        Self::SourceFetch,
        Self::SourceLocatorVerify,
    ];

    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::ClaimLanguageCheck => "claim.language_check",
            Self::ContractFindComparables => "contract.find_comparables",
            Self::EntityLookup => "entity.lookup",
            Self::EvidenceRead => "evidence.read",
            Self::EvidenceSearch => "evidence.search",
            Self::ResponseRead => "response.read",
            Self::RuleReproduce => "rule.reproduce",
            Self::SourceFetch => "source.fetch",
            Self::SourceLocatorVerify => "source.locator_verify",
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
    pub canonical_url: Option<String>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SourceLocatorVerifyRequest {
    pub binding: SnapshotBinding,
    pub expected_selected_content_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum EntityKind {
    Agency,
    Supplier,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum EntityIdentifierKind {
    CanonicalName,
    BusinessRegistrationNumber,
    AgencyCode,
    PublicSlug,
    VerifiedAlias,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EntityIdentifier {
    pub kind: EntityIdentifierKind,
    pub value: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SourceRequestKind {
    SearchPublicWeb,
    FetchUrl,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ToolRequest {
    ClaimLanguageCheck(ClaimLanguageCheckRequest),
    ContractFindComparables(ContractFindComparablesRequest),
    EntityLookup(EntityLookupRequest),
    EvidenceRead(EvidenceReadRequest),
    EvidenceSearch(EvidenceSearchRequest),
    ResponseRead(ResponseReadRequest),
    RuleReproduce(RuleReproduceRequest),
    SourceFetch(SourceFetchRequest),
    SourceLocatorVerify(SourceLocatorVerifyRequest),
}

impl ToolRequest {
    pub const fn tool_id(&self) -> ToolId {
        match self {
            Self::ClaimLanguageCheck(_) => ToolId::ClaimLanguageCheck,
            Self::ContractFindComparables(_) => ToolId::ContractFindComparables,
            Self::EntityLookup(_) => ToolId::EntityLookup,
            Self::EvidenceRead(_) => ToolId::EvidenceRead,
            Self::EvidenceSearch(_) => ToolId::EvidenceSearch,
            Self::ResponseRead(_) => ToolId::ResponseRead,
            Self::RuleReproduce(_) => ToolId::RuleReproduce,
            Self::SourceFetch(_) => ToolId::SourceFetch,
            Self::SourceLocatorVerify(_) => ToolId::SourceLocatorVerify,
        }
    }
    pub fn binding(&self) -> &SnapshotBinding {
        match self {
            Self::ClaimLanguageCheck(value) => &value.binding,
            Self::ContractFindComparables(value) => &value.binding,
            Self::EntityLookup(value) => &value.binding,
            Self::EvidenceRead(value) => &value.binding,
            Self::EvidenceSearch(value) => &value.binding,
            Self::ResponseRead(value) => &value.binding,
            Self::RuleReproduce(value) => &value.binding,
            Self::SourceFetch(value) => &value.binding,
            Self::SourceLocatorVerify(value) => &value.binding,
        }
    }
    pub const fn schema_version(&self) -> &'static str {
        match self {
            Self::ClaimLanguageCheck(_) => "claim.language_check.request.v2",
            Self::ContractFindComparables(_) => "contract.find_comparables.request.v2",
            Self::EntityLookup(_) => "entity.lookup.request.v2",
            Self::EvidenceRead(_) => "evidence.read.request.v2",
            Self::EvidenceSearch(_) => "evidence.search.request.v2",
            Self::ResponseRead(_) => "response.read.request.v2",
            Self::RuleReproduce(_) => "rule.reproduce.request.v2",
            Self::SourceFetch(_) => "source.fetch.request.v2",
            Self::SourceLocatorVerify(_) => "source.locator_verify.request.v2",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Finding {
    pub code: String,
    pub severity: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct LanguageCheckResponse {
    pub decision: String,
    pub findings: Vec<Finding>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Comparable {
    pub contract_id: Uuid,
    pub source_use_id: Uuid,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ComparablesResponse {
    pub comparables: Vec<Comparable>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EntityMatch {
    pub entity_id: Uuid,
    pub canonical_name: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EntityLookupResponse {
    pub matches: Vec<EntityMatch>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EvidenceValue {
    pub evidence_id: Uuid,
    pub source_use_id: Uuid,
    pub selected_content_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EvidenceReadResponse {
    pub evidence: EvidenceValue,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EvidenceHit {
    pub evidence_id: Uuid,
    pub source_use_id: Uuid,
    pub selected_content_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EvidenceSearchResponse {
    pub query_digest: String,
    pub hits: Vec<EvidenceHit>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ResponseValue {
    pub response_id: Uuid,
    pub response_content_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ResponseReadResponse {
    pub response: ResponseValue,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ReproductionValue {
    pub rule_run_id: Uuid,
    pub result_digest: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RuleReproduceResponse {
    pub reproduction: ReproductionValue,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SourceArtifact {
    pub research_artifact_id: Uuid,
    pub content_sha256: String,
    pub source_use_id: Uuid,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SourceFetchResponse {
    pub fetch_receipt_sha256: String,
    pub artifacts: Vec<SourceArtifact>,
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
pub enum ToolResponse {
    ClaimLanguageCheck(LanguageCheckResponse),
    ContractFindComparables(ComparablesResponse),
    EntityLookup(EntityLookupResponse),
    EvidenceRead(EvidenceReadResponse),
    EvidenceSearch(EvidenceSearchResponse),
    ResponseRead(ResponseReadResponse),
    RuleReproduce(RuleReproduceResponse),
    SourceFetch(SourceFetchResponse),
    SourceLocatorVerify(SourceLocatorVerifyResponse),
}
impl ToolResponse {
    pub const fn tool_id(&self) -> ToolId {
        match self {
            Self::ClaimLanguageCheck(_) => ToolId::ClaimLanguageCheck,
            Self::ContractFindComparables(_) => ToolId::ContractFindComparables,
            Self::EntityLookup(_) => ToolId::EntityLookup,
            Self::EvidenceRead(_) => ToolId::EvidenceRead,
            Self::EvidenceSearch(_) => ToolId::EvidenceSearch,
            Self::ResponseRead(_) => ToolId::ResponseRead,
            Self::RuleReproduce(_) => ToolId::RuleReproduce,
            Self::SourceFetch(_) => ToolId::SourceFetch,
            Self::SourceLocatorVerify(_) => ToolId::SourceLocatorVerify,
        }
    }
    pub const fn schema_version(&self) -> &'static str {
        match self {
            Self::ClaimLanguageCheck(_) => "claim.language_check.response.v2",
            Self::ContractFindComparables(_) => "contract.find_comparables.response.v2",
            Self::EntityLookup(_) => "entity.lookup.response.v2",
            Self::EvidenceRead(_) => "evidence.read.response.v2",
            Self::EvidenceSearch(_) => "evidence.search.response.v2",
            Self::ResponseRead(_) => "response.read.response.v2",
            Self::RuleReproduce(_) => "rule.reproduce.response.v2",
            Self::SourceFetch(_) => "source.fetch.response.v2",
            Self::SourceLocatorVerify(_) => "source.locator_verify.response.v2",
        }
    }
}
