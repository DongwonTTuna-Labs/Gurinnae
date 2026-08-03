use std::collections::BTreeMap;

use super::*;
use thiserror::Error;

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DispatchError {
    #[error("agent is not cataloged")]
    UnknownAgent,
    #[error("tool is not allowed for this agent")]
    ToolDenied,
    #[error("tool request is not valid for the selected adapter")]
    RequestInvalid,
    #[error("tool response belongs to another tool")]
    ResponseTypeMismatch,
    #[error("tool adapter is unavailable")]
    AdapterUnavailable,
    #[error("snapshot binding is invalid")]
    SnapshotInvalid,
}

pub trait ToolAdapter: Send + Sync {
    fn id(&self) -> ToolId;
    fn dispatch(&self, request: &ToolRequest) -> Result<ToolResponse, DispatchError>;
}

pub struct TypedDispatcher {
    adapters: BTreeMap<ToolId, Box<dyn ToolAdapter>>,
}
impl TypedDispatcher {
    pub fn new() -> Self {
        Self {
            adapters: BTreeMap::new(),
        }
    }
    pub fn register<A: ToolAdapter + 'static>(&mut self, adapter: A) {
        self.adapters.insert(adapter.id(), Box::new(adapter));
    }
    pub fn from_snapshot(snapshot: ToolSnapshot) -> Self {
        let mut dispatcher = Self::new();
        adapters::register_snapshot_adapters(&mut dispatcher, snapshot);
        dispatcher
    }
    pub fn dispatch(
        &self,
        agent: &str,
        request: &ToolRequest,
    ) -> Result<ToolResponse, DispatchError> {
        if !allowed_tools(agent).is_some_and(|tools| tools.contains(&request.tool_id())) {
            return if allowed_tools(agent).is_none() {
                Err(DispatchError::UnknownAgent)
            } else {
                Err(DispatchError::ToolDenied)
            };
        }
        let binding = request.binding();
        if binding.run_id.is_nil()
            || binding.input_snapshot_id.is_nil()
            || !is_sha256(&binding.input_snapshot_sha256)
        {
            return Err(DispatchError::SnapshotInvalid);
        }
        let adapter = self
            .adapters
            .get(&request.tool_id())
            .ok_or(DispatchError::AdapterUnavailable)?;
        let response = adapter.dispatch(request)?;
        if response.tool_id() != request.tool_id() {
            return Err(DispatchError::ResponseTypeMismatch);
        }
        Ok(response)
    }
}
impl Default for TypedDispatcher {
    fn default() -> Self {
        Self::new()
    }
}

pub(super) fn allowed_tools(agent: &str) -> Option<&'static [ToolId]> {
    const MARKET: &[ToolId] = &[
        ToolId::AgencyProfile,
        ToolId::ContractSearch,
        ToolId::EvidenceSearch,
        ToolId::RelationshipNeighbors,
        ToolId::SourceFetch,
        ToolId::SupplierProfile,
        ToolId::ContractFindComparables,
    ];
    const INVESTIGATOR: &[ToolId] = &[
        ToolId::AgencyProfile,
        ToolId::ContractSearch,
        ToolId::EvidenceSearch,
        ToolId::EvidenceRead,
        ToolId::ContractFindComparables,
        ToolId::EntityLookup,
        ToolId::RelationshipNeighbors,
        ToolId::SupplierProfile,
    ];
    const SKEPTIC: &[ToolId] = &[
        ToolId::EvidenceSearch,
        ToolId::EvidenceRead,
        ToolId::RuleReproduce,
    ];
    const DRAFTER: &[ToolId] = &[
        ToolId::EvidenceRead,
        ToolId::ResponseRead,
        ToolId::ClaimLanguageCheck,
    ];
    const VERIFIER: &[ToolId] = &[ToolId::EvidenceRead, ToolId::SourceLocatorVerify];
    match agent {
        "market-researcher" => Some(MARKET),
        "investigator" => Some(INVESTIGATOR),
        "skeptic" => Some(SKEPTIC),
        "claim-drafter" => Some(DRAFTER),
        "citation-verifier" => Some(VERIFIER),
        _ => None,
    }
}
