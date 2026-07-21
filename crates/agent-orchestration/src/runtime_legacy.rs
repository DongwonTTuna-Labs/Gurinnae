use super::*;

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

#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ToolResponse {
    ClaimLanguageCheck(LanguageCheckResponse),
    ContractFindComparables(ComparablesResponse),
    EntityLookup(EntityLookupResponse),
    EvidenceRead(EvidenceReadResponse),
    EvidenceSearch(EvidenceSearchResponse),
    ResponseRead(ResponseReadResponse),
    RuleReproduce(RuleReproduceResponse),
    /// Source fetch always uses the closed V2 response.  Keeping the legacy
    /// request/record types above is intentional for database compatibility,
    /// but no provider/tool result may cross the runtime boundary without the
    /// gateway decision and receipt fields.
    SourceFetch(SourceFetchResponseV2),
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
