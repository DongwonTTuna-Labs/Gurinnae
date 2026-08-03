//! Snapshot-scoped typed adapters for the agent dispatcher.
//!
//! The analysis worker builds one `ToolSnapshot` from a repeatable-read
//! PostgreSQL snapshot. Adapters only return records present in that snapshot;
//! they never synthesize a successful row for a missing or mismatched binding.

use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::*;

#[path = "runtime_corpus_adapters.rs"]
mod corpus_adapter;
#[path = "runtime_language_adapter.rs"]
mod language_adapter;
#[path = "runtime_relationship_adapter.rs"]
mod relationship_adapter;
#[path = "runtime_source_adapter.rs"]
mod source_adapter;

pub use corpus_adapter::{
    AgencyProfileRecord, ContractCorpusRecord, RelationshipNeighborRecord, SupplierProfileRecord,
};
pub use relationship_adapter::{RelationshipEndpointRecordV3, RelationshipNeighborRecordV3};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EvidenceRecord {
    pub evidence_id: Uuid,
    pub source_use_id: Uuid,
    pub source_use_sha256: String,
    pub selected_content_sha256: String,
    pub locator: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResponseRecord {
    pub response_id: Uuid,
    pub response_content_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComparableRecord {
    pub contract_id: Uuid,
    pub source_use_id: Uuid,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EntityRecord {
    pub entity_id: Uuid,
    pub canonical_name: String,
    pub identifiers: Vec<EntityIdentifier>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuleRecord {
    pub rule_run_id: Uuid,
    pub rule_version_id: Uuid,
    pub result_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceArtifactRecord {
    pub research_artifact_id: Uuid,
    pub source_use_id: Uuid,
    pub content_sha256: String,
    pub fetch_receipt_sha256: String,
    /// Provider-declared media type, persisted with the immutable artifact and
    /// echoed in the typed source response after byte/digest verification.
    pub content_media_type: String,
    /// The request kind and URL are persisted with the immutable research
    /// artifact.  SourceFetch must never return an artifact for a different
    /// request or broaden a URL lookup to the whole run.
    pub request_kind: SourceRequestKind,
    pub source_url: Option<String>,
    pub final_url: Option<String>,
    /// Bytes are loaded through the object-store gateway while the snapshot
    /// is materialized.  A missing capsule is a fail-closed adapter error;
    /// metadata/digests alone are not sufficient to claim a fetch result.
    pub content_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolSnapshot {
    pub binding: SnapshotBinding,
    pub evidence: Vec<EvidenceRecord>,
    pub responses: Vec<ResponseRecord>,
    pub comparables: Vec<ComparableRecord>,
    pub entities: Vec<EntityRecord>,
    pub rules: Vec<RuleRecord>,
    pub contracts: Vec<ContractCorpusRecord>,
    pub supplier_profiles: Vec<SupplierProfileRecord>,
    pub agency_profiles: Vec<AgencyProfileRecord>,
    pub relationships: Vec<RelationshipNeighborRecord>,
    pub typed_relationships: Vec<RelationshipNeighborRecordV3>,
    /// Exact canonical provider request digest validated by the typed graph
    /// database reader. It is present only for relationship.neighbors V3.
    pub typed_relationship_query_digest: Option<String>,
    pub source_artifacts: Vec<SourceArtifactRecord>,
}

impl ToolSnapshot {
    fn accepts(&self, request: &ToolRequest) -> bool {
        request.binding() == &self.binding
    }
}

pub fn register_snapshot_adapters(dispatcher: &mut TypedDispatcher, snapshot: ToolSnapshot) {
    for id in ToolId::ALL {
        dispatcher.register(SnapshotAdapter {
            id,
            snapshot: snapshot.clone(),
        });
    }
}

struct SnapshotAdapter {
    id: ToolId,
    snapshot: ToolSnapshot,
}

impl ToolAdapter for SnapshotAdapter {
    fn id(&self) -> ToolId {
        self.id
    }

    fn dispatch(&self, request: &ToolRequest) -> Result<ToolResponse, DispatchError> {
        if request.tool_id() != self.id || !self.snapshot.accepts(request) {
            return Err(DispatchError::RequestInvalid);
        }
        match request {
            ToolRequest::AgencyProfile(value) => corpus_adapter::agency_profile(self, value),
            ToolRequest::ClaimLanguageCheck(value) => language_adapter::claim_language_check(value),
            ToolRequest::ContractSearch(value) => corpus_adapter::contract_search(self, value),
            ToolRequest::ContractFindComparables(value) => self.find_comparables(value),
            ToolRequest::EntityLookup(value) => self.lookup_entity(value),
            ToolRequest::EvidenceRead(value) => self.read_evidence(value),
            ToolRequest::EvidenceSearch(value) => self.search_evidence(value),
            ToolRequest::RelationshipNeighbors(value) => {
                corpus_adapter::relationship_neighbors(self, value)
            }
            ToolRequest::RelationshipNeighborsV3(value) => {
                relationship_adapter::relationship_neighbors_v3(self, value)
            }
            ToolRequest::ResponseRead(value) => self.read_response(value),
            ToolRequest::RuleReproduce(value) => self.reproduce_rule(value),
            ToolRequest::SourceFetch(value) => self.fetch_source(value),
            ToolRequest::SourceLocatorVerify(value) => self.verify_locator(value),
            ToolRequest::SupplierProfile(value) => corpus_adapter::supplier_profile(self, value),
        }
    }
}

impl SnapshotAdapter {
    fn find_comparables(
        &self,
        value: &ContractFindComparablesRequest,
    ) -> Result<ToolResponse, DispatchError> {
        let comparables = self
            .snapshot
            .comparables
            .iter()
            .filter(|item| item.contract_id == value.subject_contract_id)
            .map(|item| Comparable {
                contract_id: item.contract_id,
                source_use_id: item.source_use_id,
            })
            .collect();
        Ok(ToolResponse::ContractFindComparables(ComparablesResponse {
            comparables,
        }))
    }
    fn lookup_entity(&self, value: &EntityLookupRequest) -> Result<ToolResponse, DispatchError> {
        let matches = self
            .snapshot
            .entities
            .iter()
            .filter(|item| {
                value
                    .identifiers
                    .iter()
                    .any(|wanted| item.identifiers.iter().any(|actual| actual == wanted))
            })
            .map(|item| EntityMatch {
                entity_id: item.entity_id,
                canonical_name: item.canonical_name.clone(),
            })
            .collect();
        Ok(ToolResponse::EntityLookup(EntityLookupResponse { matches }))
    }
    fn read_evidence(&self, value: &EvidenceReadRequest) -> Result<ToolResponse, DispatchError> {
        self.snapshot
            .evidence
            .iter()
            .find(|item| item.evidence_id == value.evidence_id)
            .map(|item| {
                ToolResponse::EvidenceRead(EvidenceReadResponse {
                    evidence: EvidenceValue {
                        evidence_id: item.evidence_id,
                        source_use_id: item.source_use_id,
                        selected_content_sha256: item.selected_content_sha256.clone(),
                    },
                })
            })
            .ok_or(DispatchError::RequestInvalid)
    }
    fn search_evidence(
        &self,
        value: &EvidenceSearchRequest,
    ) -> Result<ToolResponse, DispatchError> {
        let query = value.query.to_ascii_lowercase();
        let hits = self
            .snapshot
            .evidence
            .iter()
            .filter(|item| item.locator.to_ascii_lowercase().contains(&query))
            .map(|item| EvidenceHit {
                evidence_id: item.evidence_id,
                source_use_id: item.source_use_id,
                selected_content_sha256: item.selected_content_sha256.clone(),
            })
            .collect();
        Ok(ToolResponse::EvidenceSearch(EvidenceSearchResponse {
            query_digest: digest(value.query.as_bytes()),
            hits,
        }))
    }
    fn read_response(&self, value: &ResponseReadRequest) -> Result<ToolResponse, DispatchError> {
        self.snapshot
            .responses
            .iter()
            .find(|item| item.response_id == value.response_id)
            .map(|item| {
                ToolResponse::ResponseRead(ResponseReadResponse {
                    response: ResponseValue {
                        response_id: item.response_id,
                        response_content_sha256: item.response_content_sha256.clone(),
                    },
                })
            })
            .ok_or(DispatchError::RequestInvalid)
    }
    fn reproduce_rule(&self, value: &RuleReproduceRequest) -> Result<ToolResponse, DispatchError> {
        self.snapshot
            .rules
            .iter()
            .find(|item| item.rule_version_id == value.rule_version_id)
            .map(|item| {
                ToolResponse::RuleReproduce(RuleReproduceResponse {
                    reproduction: ReproductionValue {
                        rule_run_id: item.rule_run_id,
                        result_digest: item.result_digest.clone(),
                    },
                })
            })
            .ok_or(DispatchError::RequestInvalid)
    }
    fn fetch_source(&self, value: &SourceFetchRequest) -> Result<ToolResponse, DispatchError> {
        source_adapter::fetch(self, value)
    }
    fn verify_locator(
        &self,
        value: &SourceLocatorVerifyRequest,
    ) -> Result<ToolResponse, DispatchError> {
        let actual = self
            .snapshot
            .evidence
            .iter()
            .find(|item| item.selected_content_sha256 == value.expected_selected_content_sha256)
            .map(|item| item.selected_content_sha256.clone());
        Ok(ToolResponse::SourceLocatorVerify(
            SourceLocatorVerifyResponse {
                verification: LocatorVerification {
                    valid: actual.is_some(),
                    actual_selected_content_sha256: actual,
                },
            },
        ))
    }
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn gateway_decision(decision: &str, code: &str, policy_version: &str) -> GatewayDecisionV2 {
    let policy_sha256 = digest(policy_version.as_bytes());
    let decision_sha256 = digest(format!("{policy_version}:{decision}:{code}").as_bytes());
    GatewayDecisionV2 {
        policy_version: policy_version.to_owned(),
        policy_sha256,
        decision: decision.to_owned(),
        decision_code: code.to_owned(),
        decision_sha256,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binding() -> SnapshotBinding {
        SnapshotBinding {
            run_id: Uuid::from_u128(1),
            input_snapshot_id: Uuid::from_u128(2),
            input_snapshot_sha256: "a".repeat(64),
        }
    }

    fn artifact(bytes: &[u8]) -> SourceArtifactRecord {
        SourceArtifactRecord {
            research_artifact_id: Uuid::from_u128(3),
            source_use_id: Uuid::from_u128(4),
            content_sha256: digest(bytes),
            fetch_receipt_sha256: "b".repeat(64),
            content_media_type: "text/html".to_owned(),
            request_kind: SourceRequestKind::FetchUrl,
            source_url: Some("https://example.test/source".to_owned()),
            final_url: Some("https://example.test/final".to_owned()),
            content_bytes: Some(bytes.to_vec()),
        }
    }

    fn adapter() -> SnapshotAdapter {
        SnapshotAdapter {
            id: ToolId::SourceFetch,
            snapshot: ToolSnapshot {
                binding: binding(),
                evidence: Vec::new(),
                responses: Vec::new(),
                comparables: Vec::new(),
                entities: Vec::new(),
                rules: Vec::new(),
                contracts: Vec::new(),
                supplier_profiles: Vec::new(),
                agency_profiles: Vec::new(),
                relationships: Vec::new(),
                typed_relationships: Vec::new(),
                typed_relationship_query_digest: None,
                source_artifacts: vec![artifact(b"actual source bytes")],
            },
        }
    }

    #[test]
    fn search_never_returns_fetch_artifacts() {
        let request = ToolRequest::SourceFetch(SourceFetchRequest {
            binding: binding(),
            request_kind: SourceRequestKind::SearchPublicWeb,
            query: Some("공공 계약".to_owned()),
            locale: Some("ko-KR".to_owned()),
            country: Some("KR".to_owned()),
            recency_days: None,
            result_limit: Some(10),
            canonical_url: None,
        });
        let response = adapter().dispatch(&request).expect("search response");
        let ToolResponse::SourceFetch(response) = response else {
            panic!("unexpected response variant");
        };
        assert!(response.artifacts.is_empty());
        // The receipt binds the canonical JSON array of zero search
        // artifacts, not an empty byte payload.
        assert_eq!(response.fetch_receipt_sha256, digest(b"[]"));
    }

    #[test]
    fn fetch_requires_exact_url_and_content_digest() {
        let request = ToolRequest::SourceFetch(SourceFetchRequest {
            binding: binding(),
            request_kind: SourceRequestKind::FetchUrl,
            query: None,
            locale: None,
            country: None,
            recency_days: None,
            result_limit: None,
            canonical_url: Some("https://example.test/final".to_owned()),
        });
        let response = adapter().dispatch(&request).expect("fetch response");
        let ToolResponse::SourceFetch(response) = response else {
            panic!("unexpected response variant");
        };
        assert_eq!(response.artifacts.len(), 1);
        assert_eq!(
            response.fetch_receipt_sha256,
            digest(b"actual source bytes")
        );

        let wrong_url = ToolRequest::SourceFetch(SourceFetchRequest {
            binding: binding(),
            request_kind: SourceRequestKind::FetchUrl,
            query: None,
            locale: None,
            country: None,
            recency_days: None,
            result_limit: None,
            canonical_url: Some("https://example.test/other".to_owned()),
        });
        assert!(matches!(
            adapter().dispatch(&wrong_url),
            Err(DispatchError::RequestInvalid)
        ));
    }
}
