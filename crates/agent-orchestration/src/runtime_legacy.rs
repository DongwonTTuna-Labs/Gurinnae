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
    AgencyProfile(AgencyProfileRequest),
    ClaimLanguageCheck(ClaimLanguageCheckRequest),
    ContractSearch(ContractSearchRequest),
    ContractFindComparables(ContractFindComparablesRequest),
    EntityLookup(EntityLookupRequest),
    EvidenceRead(EvidenceReadRequest),
    EvidenceSearch(EvidenceSearchRequest),
    RelationshipNeighbors(RelationshipNeighborsRequest),
    ResponseRead(ResponseReadRequest),
    RuleReproduce(RuleReproduceRequest),
    SourceFetch(SourceFetchRequest),
    SourceLocatorVerify(SourceLocatorVerifyRequest),
    SupplierProfile(SupplierProfileRequest),
}

impl ToolRequest {
    pub const fn tool_id(&self) -> ToolId {
        match self {
            Self::AgencyProfile(_) => ToolId::AgencyProfile,
            Self::ClaimLanguageCheck(_) => ToolId::ClaimLanguageCheck,
            Self::ContractSearch(_) => ToolId::ContractSearch,
            Self::ContractFindComparables(_) => ToolId::ContractFindComparables,
            Self::EntityLookup(_) => ToolId::EntityLookup,
            Self::EvidenceRead(_) => ToolId::EvidenceRead,
            Self::EvidenceSearch(_) => ToolId::EvidenceSearch,
            Self::RelationshipNeighbors(_) => ToolId::RelationshipNeighbors,
            Self::ResponseRead(_) => ToolId::ResponseRead,
            Self::RuleReproduce(_) => ToolId::RuleReproduce,
            Self::SourceFetch(_) => ToolId::SourceFetch,
            Self::SourceLocatorVerify(_) => ToolId::SourceLocatorVerify,
            Self::SupplierProfile(_) => ToolId::SupplierProfile,
        }
    }
    pub fn binding(&self) -> &SnapshotBinding {
        match self {
            Self::AgencyProfile(value) => &value.binding,
            Self::ClaimLanguageCheck(value) => &value.binding,
            Self::ContractSearch(value) => &value.binding,
            Self::ContractFindComparables(value) => &value.binding,
            Self::EntityLookup(value) => &value.binding,
            Self::EvidenceRead(value) => &value.binding,
            Self::EvidenceSearch(value) => &value.binding,
            Self::RelationshipNeighbors(value) => &value.binding,
            Self::ResponseRead(value) => &value.binding,
            Self::RuleReproduce(value) => &value.binding,
            Self::SourceFetch(value) => &value.binding,
            Self::SourceLocatorVerify(value) => &value.binding,
            Self::SupplierProfile(value) => &value.binding,
        }
    }
    pub const fn schema_version(&self) -> &'static str {
        match self {
            Self::AgencyProfile(_) => "agency.profile.request.v2",
            Self::ClaimLanguageCheck(_) => "claim.language_check.request.v2",
            Self::ContractSearch(_) => "contract.search.request.v2",
            Self::ContractFindComparables(_) => "contract.find_comparables.request.v2",
            Self::EntityLookup(_) => "entity.lookup.request.v2",
            Self::EvidenceRead(_) => "evidence.read.request.v2",
            Self::EvidenceSearch(_) => "evidence.search.request.v2",
            Self::RelationshipNeighbors(_) => "relationship.neighbors.request.v2",
            Self::ResponseRead(_) => "response.read.request.v2",
            Self::RuleReproduce(_) => "rule.reproduce.request.v2",
            Self::SourceFetch(_) => "source.fetch.request.v2",
            Self::SourceLocatorVerify(_) => "source.locator_verify.request.v2",
            Self::SupplierProfile(_) => "supplier.profile.request.v2",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    pub finding_id: Uuid,
    pub code: LanguageFindingCode,
    pub severity: LanguageFindingSeverity,
    pub start_utf16: u32,
    pub end_utf16: u32,
    pub length_utf16: u32,
    pub message: String,
    pub suggested_replacement: Option<String>,
    pub citation_ids: Vec<Uuid>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LanguageFindingCode {
    UnsupportedCertainty,
    CrimeOrCorruptionAssertion,
    NoResponseAsAdmission,
    MissingLimitation,
    AmbiguousActor,
    UnattributedQuote,
    PersonalData,
    InaccessibleLanguage,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LanguageFindingSeverity {
    Info,
    Warning,
    Blocking,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LanguageDecision {
    Pass,
    Revise,
    Block,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanguageCheckResponse {
    pub schema_version: String,
    pub checked_text_sha256: String,
    pub checked_text_utf16_length: u32,
    pub decision: LanguageDecision,
    pub findings: Vec<Finding>,
    pub finding_limit: u8,
    pub total_findings: u32,
    pub truncated: bool,
    pub language_decision_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContractSearchResponse {
    pub schema_version: String,
    pub query_digest: String,
    pub contracts: Vec<ContractSearchHit>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContractSearchHit {
    pub contract_id: Uuid,
    pub title: String,
    pub agency_id: Uuid,
    pub supplier_id: Option<Uuid>,
    pub status: String,
    pub procurement_method: Option<String>,
    pub signed_at: Option<String>,
    pub currency: String,
    pub amount: Option<String>,
    pub snapshot_member_id: Uuid,
    pub snapshot_member_digest: String,
    pub source_use_id: Uuid,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SupplierProfileResponse {
    pub schema_version: String,
    pub profile: SupplierProfile,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SupplierProfile {
    pub supplier_id: Uuid,
    pub canonical_name: String,
    pub business_status: Option<String>,
    pub identity_status: SupplierIdentityStatus,
    pub contract_count: u32,
    pub snapshot_member_id: Uuid,
    pub snapshot_member_digest: String,
    pub source_use_id: Uuid,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SupplierIdentityStatus {
    Unverified,
    Candidate,
    Verified,
    Ambiguous,
    Conflicted,
    Rejected,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgencyProfileResponse {
    pub schema_version: String,
    pub profile: AgencyProfile,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgencyProfile {
    pub agency_id: Uuid,
    pub canonical_name: String,
    pub agency_type: String,
    pub jurisdiction: Option<String>,
    pub active: bool,
    pub contract_count: u32,
    pub snapshot_member_id: Uuid,
    pub snapshot_member_digest: String,
    pub source_use_id: Uuid,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelationshipNeighborsResponse {
    pub schema_version: String,
    pub supplier_id: Uuid,
    pub neighbors: Vec<RelationshipNeighbor>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelationshipNeighbor {
    pub neighbor_supplier_id: Uuid,
    pub relationship_kind: RelationshipKind,
    pub assertion_id: Uuid,
    pub assertion_revision: u64,
    pub assertion_digest: String,
    pub valid_from: Option<String>,
    pub valid_to: Option<String>,
    pub evidence_set_digest: String,
    pub subject_source_use_id: Uuid,
    pub object_source_use_id: Uuid,
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
#[serde(untagged)]
pub enum ToolResponse {
    AgencyProfile(AgencyProfileResponse),
    ClaimLanguageCheck(LanguageCheckResponse),
    ContractSearch(ContractSearchResponse),
    ContractFindComparables(ComparablesResponse),
    EntityLookup(EntityLookupResponse),
    EvidenceRead(EvidenceReadResponse),
    EvidenceSearch(EvidenceSearchResponse),
    RelationshipNeighbors(RelationshipNeighborsResponse),
    ResponseRead(ResponseReadResponse),
    RuleReproduce(RuleReproduceResponse),
    /// Source fetch always uses the closed V2 response.  Keeping the legacy
    /// request/record types above is intentional for database compatibility,
    /// but no provider/tool result may cross the runtime boundary without the
    /// gateway decision and receipt fields.
    SourceFetch(SourceFetchResponseV2),
    SourceLocatorVerify(SourceLocatorVerifyResponse),
    SupplierProfile(SupplierProfileResponse),
}
impl ToolResponse {
    pub const fn tool_id(&self) -> ToolId {
        match self {
            Self::AgencyProfile(_) => ToolId::AgencyProfile,
            Self::ClaimLanguageCheck(_) => ToolId::ClaimLanguageCheck,
            Self::ContractSearch(_) => ToolId::ContractSearch,
            Self::ContractFindComparables(_) => ToolId::ContractFindComparables,
            Self::EntityLookup(_) => ToolId::EntityLookup,
            Self::EvidenceRead(_) => ToolId::EvidenceRead,
            Self::EvidenceSearch(_) => ToolId::EvidenceSearch,
            Self::RelationshipNeighbors(_) => ToolId::RelationshipNeighbors,
            Self::ResponseRead(_) => ToolId::ResponseRead,
            Self::RuleReproduce(_) => ToolId::RuleReproduce,
            Self::SourceFetch(_) => ToolId::SourceFetch,
            Self::SourceLocatorVerify(_) => ToolId::SourceLocatorVerify,
            Self::SupplierProfile(_) => ToolId::SupplierProfile,
        }
    }
    pub const fn schema_version(&self) -> &'static str {
        match self {
            Self::AgencyProfile(_) => "agency.profile.response.v2",
            Self::ClaimLanguageCheck(_) => "claim.language_check.response.v2",
            Self::ContractSearch(_) => "contract.search.response.v2",
            Self::ContractFindComparables(_) => "contract.find_comparables.response.v2",
            Self::EntityLookup(_) => "entity.lookup.response.v2",
            Self::EvidenceRead(_) => "evidence.read.response.v2",
            Self::EvidenceSearch(_) => "evidence.search.response.v2",
            Self::RelationshipNeighbors(_) => "relationship.neighbors.response.v2",
            Self::ResponseRead(_) => "response.read.response.v2",
            Self::RuleReproduce(_) => "rule.reproduce.response.v2",
            Self::SourceFetch(_) => "source.fetch.response.v2",
            Self::SourceLocatorVerify(_) => "source.locator_verify.response.v2",
            Self::SupplierProfile(_) => "supplier.profile.response.v2",
        }
    }

    /// Return the exact immutable snapshot roots represented by a corpus
    /// response. Other tools keep their established provenance behavior.
    /// Sorting and deduplication make the parent set deterministic even when
    /// two verified relationship assertions share one endpoint root.
    pub fn corpus_source_use_ids(&self) -> Option<Vec<Uuid>> {
        let mut ids = match self {
            Self::AgencyProfile(response) => vec![response.profile.source_use_id],
            Self::ContractSearch(response) => response
                .contracts
                .iter()
                .map(|contract| contract.source_use_id)
                .collect(),
            Self::RelationshipNeighbors(response) => response
                .neighbors
                .iter()
                .flat_map(|neighbor| {
                    [
                        neighbor.subject_source_use_id,
                        neighbor.object_source_use_id,
                    ]
                })
                .collect(),
            Self::SupplierProfile(response) => vec![response.profile.source_use_id],
            _ => return None,
        };
        ids.sort_unstable();
        ids.dedup();
        Some(ids)
    }
}

#[cfg(test)]
mod corpus_source_use_tests {
    use super::*;

    #[test]
    fn corpus_responses_expose_only_returned_snapshot_roots() {
        let first = Uuid::from_u128(1);
        let second = Uuid::from_u128(2);
        let response = ToolResponse::ContractSearch(ContractSearchResponse {
            schema_version: "contract.search.response.v2".to_owned(),
            query_digest: "a".repeat(64),
            contracts: vec![
                contract_hit(Uuid::from_u128(11), second),
                contract_hit(Uuid::from_u128(12), first),
                contract_hit(Uuid::from_u128(13), second),
            ],
        });
        assert_eq!(response.corpus_source_use_ids(), Some(vec![first, second]));
    }

    #[test]
    fn relationship_response_binds_both_verified_endpoint_roots() {
        let first = Uuid::from_u128(1);
        let second = Uuid::from_u128(2);
        let response = ToolResponse::RelationshipNeighbors(RelationshipNeighborsResponse {
            schema_version: "relationship.neighbors.response.v2".to_owned(),
            supplier_id: Uuid::from_u128(3),
            neighbors: vec![RelationshipNeighbor {
                neighbor_supplier_id: Uuid::from_u128(4),
                relationship_kind: RelationshipKind::Ownership,
                assertion_id: Uuid::from_u128(5),
                assertion_revision: 1,
                assertion_digest: "b".repeat(64),
                valid_from: None,
                valid_to: None,
                evidence_set_digest: "c".repeat(64),
                subject_source_use_id: second,
                object_source_use_id: first,
            }],
        });
        assert_eq!(response.corpus_source_use_ids(), Some(vec![first, second]));
    }

    #[test]
    fn profile_responses_expose_their_snapshot_root_for_source_use_registration() {
        let supplier_root = Uuid::from_u128(7);
        let agency_root = Uuid::from_u128(8);
        let supplier = ToolResponse::SupplierProfile(SupplierProfileResponse {
            schema_version: "supplier.profile.response.v2".to_owned(),
            profile: SupplierProfile {
                supplier_id: Uuid::from_u128(9),
                canonical_name: "가상 공급자".to_owned(),
                business_status: None,
                identity_status: SupplierIdentityStatus::Unverified,
                contract_count: 0,
                snapshot_member_id: Uuid::from_u128(10),
                snapshot_member_digest: "a".repeat(64),
                source_use_id: supplier_root,
            },
        });
        let agency = ToolResponse::AgencyProfile(AgencyProfileResponse {
            schema_version: "agency.profile.response.v2".to_owned(),
            profile: AgencyProfile {
                agency_id: Uuid::from_u128(11),
                canonical_name: "가상 기관".to_owned(),
                agency_type: "PUBLIC".to_owned(),
                jurisdiction: None,
                active: true,
                contract_count: 0,
                snapshot_member_id: Uuid::from_u128(12),
                snapshot_member_digest: "b".repeat(64),
                source_use_id: agency_root,
            },
        });
        assert_eq!(supplier.corpus_source_use_ids(), Some(vec![supplier_root]));
        assert_eq!(agency.corpus_source_use_ids(), Some(vec![agency_root]));
    }

    #[test]
    fn legacy_tool_responses_keep_their_existing_provenance_path() {
        let response = ToolResponse::EvidenceSearch(EvidenceSearchResponse {
            query_digest: "d".repeat(64),
            hits: Vec::new(),
        });
        assert_eq!(response.corpus_source_use_ids(), None);
    }

    #[test]
    fn supplier_identity_status_is_closed_at_the_wire_boundary() {
        assert_eq!(
            serde_json::from_str::<SupplierIdentityStatus>("\"UNVERIFIED\"").ok(),
            Some(SupplierIdentityStatus::Unverified)
        );
        assert!(serde_json::from_str::<SupplierIdentityStatus>("\"NAME_MATCHED\"").is_err());
    }

    fn contract_hit(contract_id: Uuid, source_use_id: Uuid) -> ContractSearchHit {
        ContractSearchHit {
            contract_id,
            title: "계약".to_owned(),
            agency_id: Uuid::from_u128(20),
            supplier_id: None,
            status: "ACTIVE".to_owned(),
            procurement_method: None,
            signed_at: None,
            currency: "KRW".to_owned(),
            amount: None,
            snapshot_member_id: Uuid::from_u128(21),
            snapshot_member_digest: "e".repeat(64),
            source_use_id,
        }
    }
}
