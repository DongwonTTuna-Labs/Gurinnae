//! Snapshot-scoped typed adapters for the agent dispatcher.
//!
//! The analysis worker builds one `ToolSnapshot` from a repeatable-read
//! PostgreSQL snapshot. Adapters only return records present in that snapshot;
//! they never synthesize a successful row for a missing or mismatched binding.

use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EvidenceRecord {
    pub evidence_id: Uuid,
    pub source_use_id: Uuid,
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
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolSnapshot {
    pub binding: SnapshotBinding,
    pub evidence: Vec<EvidenceRecord>,
    pub responses: Vec<ResponseRecord>,
    pub comparables: Vec<ComparableRecord>,
    pub entities: Vec<EntityRecord>,
    pub rules: Vec<RuleRecord>,
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
            ToolRequest::ClaimLanguageCheck(value) => self.claim_language_check(value),
            ToolRequest::ContractFindComparables(value) => self.find_comparables(value),
            ToolRequest::EntityLookup(value) => self.lookup_entity(value),
            ToolRequest::EvidenceRead(value) => self.read_evidence(value),
            ToolRequest::EvidenceSearch(value) => self.search_evidence(value),
            ToolRequest::ResponseRead(value) => self.read_response(value),
            ToolRequest::RuleReproduce(value) => self.reproduce_rule(value),
            ToolRequest::SourceFetch(value) => self.fetch_source(value),
            ToolRequest::SourceLocatorVerify(value) => self.verify_locator(value),
        }
    }
}

impl SnapshotAdapter {
    fn claim_language_check(&self, value: &ClaimLanguageCheckRequest) -> Result<ToolResponse, DispatchError> {
        if value.draft_text.trim().is_empty() { return Err(DispatchError::RequestInvalid); }
        Ok(ToolResponse::ClaimLanguageCheck(LanguageCheckResponse { decision: "REVIEW_REQUIRED".to_owned(), findings: Vec::new() }))
    }
    fn find_comparables(&self, value: &ContractFindComparablesRequest) -> Result<ToolResponse, DispatchError> {
        let comparables = self.snapshot.comparables.iter().filter(|item| item.contract_id == value.subject_contract_id)
            .map(|item| Comparable { contract_id: item.contract_id, source_use_id: item.source_use_id }).collect();
        Ok(ToolResponse::ContractFindComparables(ComparablesResponse { comparables }))
    }
    fn lookup_entity(&self, value: &EntityLookupRequest) -> Result<ToolResponse, DispatchError> {
        let matches = self.snapshot.entities.iter().filter(|item| value.identifiers.iter().any(|wanted| item.identifiers.iter().any(|actual| actual == wanted)))
            .map(|item| EntityMatch { entity_id: item.entity_id, canonical_name: item.canonical_name.clone() }).collect();
        Ok(ToolResponse::EntityLookup(EntityLookupResponse { matches }))
    }
    fn read_evidence(&self, value: &EvidenceReadRequest) -> Result<ToolResponse, DispatchError> {
        self.snapshot.evidence.iter().find(|item| item.evidence_id == value.evidence_id)
            .map(|item| ToolResponse::EvidenceRead(EvidenceReadResponse { evidence: EvidenceValue { evidence_id: item.evidence_id, source_use_id: item.source_use_id, selected_content_sha256: item.selected_content_sha256.clone() } }))
            .ok_or(DispatchError::RequestInvalid)
    }
    fn search_evidence(&self, value: &EvidenceSearchRequest) -> Result<ToolResponse, DispatchError> {
        let query = value.query.to_ascii_lowercase();
        let hits = self.snapshot.evidence.iter().filter(|item| item.locator.to_ascii_lowercase().contains(&query))
            .map(|item| EvidenceHit { evidence_id: item.evidence_id, source_use_id: item.source_use_id, selected_content_sha256: item.selected_content_sha256.clone() }).collect();
        Ok(ToolResponse::EvidenceSearch(EvidenceSearchResponse { query_digest: digest(value.query.as_bytes()), hits }))
    }
    fn read_response(&self, value: &ResponseReadRequest) -> Result<ToolResponse, DispatchError> {
        self.snapshot.responses.iter().find(|item| item.response_id == value.response_id)
            .map(|item| ToolResponse::ResponseRead(ResponseReadResponse { response: ResponseValue { response_id: item.response_id, response_content_sha256: item.response_content_sha256.clone() } }))
            .ok_or(DispatchError::RequestInvalid)
    }
    fn reproduce_rule(&self, value: &RuleReproduceRequest) -> Result<ToolResponse, DispatchError> {
        self.snapshot.rules.iter().find(|item| item.rule_version_id == value.rule_version_id)
            .map(|item| ToolResponse::RuleReproduce(RuleReproduceResponse { reproduction: ReproductionValue { rule_run_id: item.rule_run_id, result_digest: item.result_digest.clone() } }))
            .ok_or(DispatchError::RequestInvalid)
    }
    fn fetch_source(&self, value: &SourceFetchRequest) -> Result<ToolResponse, DispatchError> {
        if matches!(value.request_kind, SourceRequestKind::FetchUrl) && value.canonical_url.as_deref().is_none_or(str::is_empty) { return Err(DispatchError::RequestInvalid); }
        let artifacts = self.snapshot.source_artifacts.iter().map(|item| SourceArtifact { research_artifact_id: item.research_artifact_id, content_sha256: item.content_sha256.clone(), source_use_id: item.source_use_id }).collect();
        Ok(ToolResponse::SourceFetch(SourceFetchResponse { fetch_receipt_sha256: digest(value.canonical_url.as_deref().unwrap_or("search").as_bytes()), artifacts }))
    }
    fn verify_locator(&self, value: &SourceLocatorVerifyRequest) -> Result<ToolResponse, DispatchError> {
        let actual = self.snapshot.evidence.iter().find(|item| item.selected_content_sha256 == value.expected_selected_content_sha256).map(|item| item.selected_content_sha256.clone());
        Ok(ToolResponse::SourceLocatorVerify(SourceLocatorVerifyResponse { verification: LocatorVerification { valid: actual.is_some(), actual_selected_content_sha256: actual } }))
    }
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
