use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContractCorpusRecord {
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SupplierProfileRecord {
    pub supplier_id: Uuid,
    pub canonical_name: String,
    pub business_status: Option<String>,
    pub identity_status: SupplierIdentityStatus,
    pub contract_count: u32,
    pub snapshot_member_id: Uuid,
    pub snapshot_member_digest: String,
    pub source_use_id: Uuid,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgencyProfileRecord {
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipNeighborRecord {
    pub subject_supplier_id: Uuid,
    pub object_supplier_id: Uuid,
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

pub(super) fn contract_search(
    adapter: &SnapshotAdapter,
    value: &ContractSearchRequest,
) -> Result<ToolResponse, DispatchError> {
    let entity_shape_valid =
        matches!(value.entity_kind, ContractEntityKind::Any) == value.entity_id.is_none();
    if !entity_shape_valid || !valid_contract_search(value) {
        return Err(DispatchError::RequestInvalid);
    }
    let mut rows = adapter
        .snapshot
        .contracts
        .iter()
        .filter(|record| contract_matches(record, value))
        .cloned()
        .collect::<Vec<_>>();
    rows.sort_by(|left, right| {
        right
            .signed_at
            .cmp(&left.signed_at)
            .then_with(|| left.contract_id.cmp(&right.contract_id))
    });
    rows.truncate(usize::from(value.limit));
    let contracts = rows.into_iter().map(contract_hit).collect();
    Ok(ToolResponse::ContractSearch(ContractSearchResponse {
        schema_version: "contract.search.response.v2".to_owned(),
        query_digest: digest(
            &serde_json::to_vec(value).map_err(|_| DispatchError::RequestInvalid)?,
        ),
        contracts,
    }))
}

pub(super) fn supplier_profile(
    adapter: &SnapshotAdapter,
    value: &SupplierProfileRequest,
) -> Result<ToolResponse, DispatchError> {
    adapter
        .snapshot
        .supplier_profiles
        .iter()
        .find(|record| record.supplier_id == value.supplier_id)
        .map(|record| {
            ToolResponse::SupplierProfile(SupplierProfileResponse {
                schema_version: "supplier.profile.response.v2".to_owned(),
                profile: SupplierProfile {
                    supplier_id: record.supplier_id,
                    canonical_name: record.canonical_name.clone(),
                    business_status: record.business_status.clone(),
                    identity_status: record.identity_status,
                    contract_count: record.contract_count,
                    snapshot_member_id: record.snapshot_member_id,
                    snapshot_member_digest: record.snapshot_member_digest.clone(),
                    source_use_id: record.source_use_id,
                },
            })
        })
        .ok_or(DispatchError::RequestInvalid)
}

pub(super) fn agency_profile(
    adapter: &SnapshotAdapter,
    value: &AgencyProfileRequest,
) -> Result<ToolResponse, DispatchError> {
    adapter
        .snapshot
        .agency_profiles
        .iter()
        .find(|record| record.agency_id == value.agency_id)
        .map(|record| {
            ToolResponse::AgencyProfile(AgencyProfileResponse {
                schema_version: "agency.profile.response.v2".to_owned(),
                profile: AgencyProfile {
                    agency_id: record.agency_id,
                    canonical_name: record.canonical_name.clone(),
                    agency_type: record.agency_type.clone(),
                    jurisdiction: record.jurisdiction.clone(),
                    active: record.active,
                    contract_count: record.contract_count,
                    snapshot_member_id: record.snapshot_member_id,
                    snapshot_member_digest: record.snapshot_member_digest.clone(),
                    source_use_id: record.source_use_id,
                },
            })
        })
        .ok_or(DispatchError::RequestInvalid)
}

pub(super) fn relationship_neighbors(
    adapter: &SnapshotAdapter,
    value: &RelationshipNeighborsRequest,
) -> Result<ToolResponse, DispatchError> {
    if !(1..=50).contains(&value.limit)
        || value.as_of.as_ref().is_some_and(|date| !valid_date(date))
    {
        return Err(DispatchError::RequestInvalid);
    }
    let mut rows = adapter
        .snapshot
        .relationships
        .iter()
        .filter(|record| relationship_matches(record, value))
        .map(|record| neighbor(record, value.supplier_id))
        .collect::<Vec<_>>();
    rows.sort_by(|left, right| {
        left.relationship_kind
            .cmp(&right.relationship_kind)
            .then_with(|| left.neighbor_supplier_id.cmp(&right.neighbor_supplier_id))
            .then_with(|| left.assertion_id.cmp(&right.assertion_id))
            .then_with(|| left.assertion_revision.cmp(&right.assertion_revision))
    });
    rows.truncate(usize::from(value.limit));
    Ok(ToolResponse::RelationshipNeighbors(
        RelationshipNeighborsResponse {
            schema_version: "relationship.neighbors.response.v2".to_owned(),
            supplier_id: value.supplier_id,
            neighbors: rows,
        },
    ))
}

fn valid_contract_search(value: &ContractSearchRequest) -> bool {
    (1..=50).contains(&value.limit)
        && value.from_date.as_ref().is_none_or(|date| valid_date(date))
        && value.to_date.as_ref().is_none_or(|date| valid_date(date))
        && value
            .from_date
            .as_ref()
            .zip(value.to_date.as_ref())
            .is_none_or(|(from, to)| from <= to)
        && value
            .procurement_methods
            .iter()
            .all(|method| !method.trim().is_empty() && method.len() <= 200)
}

fn contract_hit(record: ContractCorpusRecord) -> ContractSearchHit {
    ContractSearchHit {
        contract_id: record.contract_id,
        title: record.title,
        agency_id: record.agency_id,
        supplier_id: record.supplier_id,
        status: record.status,
        procurement_method: record.procurement_method,
        signed_at: record.signed_at,
        currency: record.currency,
        amount: record.amount,
        snapshot_member_id: record.snapshot_member_id,
        snapshot_member_digest: record.snapshot_member_digest,
        source_use_id: record.source_use_id,
    }
}

fn neighbor(record: &RelationshipNeighborRecord, supplier_id: Uuid) -> RelationshipNeighbor {
    RelationshipNeighbor {
        neighbor_supplier_id: if record.subject_supplier_id == supplier_id {
            record.object_supplier_id
        } else {
            record.subject_supplier_id
        },
        relationship_kind: record.relationship_kind,
        assertion_id: record.assertion_id,
        assertion_revision: record.assertion_revision,
        assertion_digest: record.assertion_digest.clone(),
        valid_from: record.valid_from.clone(),
        valid_to: record.valid_to.clone(),
        evidence_set_digest: record.evidence_set_digest.clone(),
        subject_source_use_id: record.subject_source_use_id,
        object_source_use_id: record.object_source_use_id,
    }
}

fn valid_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 10
        && bytes[0..4].iter().all(u8::is_ascii_digit)
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(u8::is_ascii_digit)
}

fn contract_matches(record: &ContractCorpusRecord, request: &ContractSearchRequest) -> bool {
    let entity_matches = match (request.entity_kind, request.entity_id) {
        (ContractEntityKind::Any, None) => true,
        (ContractEntityKind::Agency, Some(id)) => record.agency_id == id,
        (ContractEntityKind::Supplier, Some(id)) => record.supplier_id == Some(id),
        _ => false,
    };
    let date_matches = request.from_date.as_ref().is_none_or(|from| {
        record
            .signed_at
            .as_ref()
            .is_some_and(|signed| signed >= from)
    }) && request
        .to_date
        .as_ref()
        .is_none_or(|to| record.signed_at.as_ref().is_some_and(|signed| signed <= to));
    let method_matches = request.procurement_methods.is_empty()
        || record
            .procurement_method
            .as_ref()
            .is_some_and(|method| request.procurement_methods.contains(method));
    entity_matches && date_matches && method_matches
}

fn relationship_matches(
    record: &RelationshipNeighborRecord,
    request: &RelationshipNeighborsRequest,
) -> bool {
    let endpoint_matches = record.subject_supplier_id == request.supplier_id
        || record.object_supplier_id == request.supplier_id;
    let kind_matches = request.relationship_kinds.is_empty()
        || request
            .relationship_kinds
            .contains(&record.relationship_kind);
    let date_matches = request.as_of.as_ref().is_none_or(|as_of| {
        record.valid_from.as_ref().is_none_or(|from| from <= as_of)
            && record.valid_to.as_ref().is_none_or(|to| to >= as_of)
    });
    endpoint_matches && kind_matches && date_matches
}
