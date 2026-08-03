use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelationshipEndpointRecordV3 {
    Supplier { endpoint_id: Uuid },
    Person { person_node_ref: String },
    Agency { endpoint_id: Uuid },
    ProcurementNotice { endpoint_id: Uuid },
    Sanction { endpoint_id: Uuid },
}

impl RelationshipEndpointRecordV3 {
    fn kind(&self) -> RelationshipEndpointKindV3 {
        match self {
            Self::Supplier { .. } => RelationshipEndpointKindV3::Supplier,
            Self::Person { .. } => RelationshipEndpointKindV3::Person,
            Self::Agency { .. } => RelationshipEndpointKindV3::Agency,
            Self::ProcurementNotice { .. } => RelationshipEndpointKindV3::ProcurementNotice,
            Self::Sanction { .. } => RelationshipEndpointKindV3::Sanction,
        }
    }

    fn matches(&self, selector: &RelationshipEndpointSelectorV3) -> bool {
        match (self, selector) {
            (
                Self::Supplier {
                    endpoint_id: actual,
                },
                RelationshipEndpointSelectorV3::Supplier {
                    endpoint_id: expected,
                },
            )
            | (
                Self::Agency {
                    endpoint_id: actual,
                },
                RelationshipEndpointSelectorV3::Agency {
                    endpoint_id: expected,
                },
            )
            | (
                Self::ProcurementNotice {
                    endpoint_id: actual,
                },
                RelationshipEndpointSelectorV3::ProcurementNotice {
                    endpoint_id: expected,
                },
            )
            | (
                Self::Sanction {
                    endpoint_id: actual,
                },
                RelationshipEndpointSelectorV3::Sanction {
                    endpoint_id: expected,
                },
            ) => actual == expected,
            (
                Self::Person {
                    person_node_ref: actual,
                    ..
                },
                RelationshipEndpointSelectorV3::Person {
                    person_node_ref: expected,
                },
            ) => actual == expected,
            _ => false,
        }
    }

    fn wire_endpoint(&self) -> RelationshipEndpointV3 {
        match self {
            Self::Supplier { endpoint_id } => RelationshipEndpointV3::Supplier {
                endpoint_id: *endpoint_id,
            },
            Self::Person {
                person_node_ref, ..
            } => RelationshipEndpointV3::Person {
                person_node_ref: person_node_ref.clone(),
            },
            Self::Agency { endpoint_id } => RelationshipEndpointV3::Agency {
                endpoint_id: *endpoint_id,
            },
            Self::ProcurementNotice { endpoint_id } => RelationshipEndpointV3::ProcurementNotice {
                endpoint_id: *endpoint_id,
            },
            Self::Sanction { endpoint_id } => RelationshipEndpointV3::Sanction {
                endpoint_id: *endpoint_id,
            },
        }
    }

    fn stable_key(&self) -> String {
        self.wire_endpoint().stable_key()
    }

    fn is_valid(&self) -> bool {
        match self {
            Self::Supplier { endpoint_id }
            | Self::Agency { endpoint_id }
            | Self::ProcurementNotice { endpoint_id }
            | Self::Sanction { endpoint_id } => !endpoint_id.is_nil(),
            Self::Person { person_node_ref } => lower_sha256(person_node_ref),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipNeighborRecordV3 {
    pub subject: RelationshipEndpointRecordV3,
    pub object: RelationshipEndpointRecordV3,
    pub relationship_kind: RelationshipKindV3,
    pub assertion_id: Uuid,
    pub assertion_revision: u64,
    pub assertion_digest: String,
    pub valid_from: Option<String>,
    pub valid_to: Option<String>,
    pub evidence_set_digest: String,
    pub subject_source_use_id: Uuid,
    pub object_source_use_id: Uuid,
}

impl RelationshipNeighborRecordV3 {
    fn is_valid(&self) -> bool {
        self.subject.is_valid()
            && self.object.is_valid()
            && self.valid_pair()
            && (self.subject.kind(), self.subject.stable_key())
                != (self.object.kind(), self.object.stable_key())
            && !self.assertion_id.is_nil()
            && self.assertion_revision > 0
            && lower_sha256(&self.assertion_digest)
            && self.valid_from.as_ref().is_none_or(|date| valid_date(date))
            && self.valid_to.as_ref().is_none_or(|date| valid_date(date))
            && self
                .valid_from
                .as_ref()
                .zip(self.valid_to.as_ref())
                .is_none_or(|(from, to)| from <= to)
            && lower_sha256(&self.evidence_set_digest)
            && !self.subject_source_use_id.is_nil()
            && !self.object_source_use_id.is_nil()
    }

    fn valid_pair(&self) -> bool {
        matches!(
            (
                self.relationship_kind,
                self.subject.kind(),
                self.object.kind()
            ),
            (
                RelationshipKindV3::Ownership
                    | RelationshipKindV3::BeneficialOwnership
                    | RelationshipKindV3::Control
                    | RelationshipKindV3::ContractualRelationship,
                RelationshipEndpointKindV3::Supplier,
                RelationshipEndpointKindV3::Supplier
            ) | (
                RelationshipKindV3::ManagementRole | RelationshipKindV3::LegalRepresentative,
                RelationshipEndpointKindV3::Person,
                RelationshipEndpointKindV3::Supplier
            ) | (
                RelationshipKindV3::BidParticipation,
                RelationshipEndpointKindV3::Supplier,
                RelationshipEndpointKindV3::ProcurementNotice
            ) | (
                RelationshipKindV3::Sanction,
                RelationshipEndpointKindV3::Supplier,
                RelationshipEndpointKindV3::Sanction
            ) | (
                RelationshipKindV3::FormerOfficialRole,
                RelationshipEndpointKindV3::Person,
                RelationshipEndpointKindV3::Agency
            )
        )
    }
}

pub(super) fn relationship_neighbors_v3(
    adapter: &SnapshotAdapter,
    request: &RelationshipNeighborsRequestV3,
) -> Result<ToolResponse, DispatchError> {
    if !valid_request(request) {
        return Err(DispatchError::RequestInvalid);
    }
    let query_digest = adapter
        .snapshot
        .typed_relationship_query_digest
        .as_ref()
        .filter(|digest| lower_sha256(digest))
        .cloned()
        .ok_or(DispatchError::RequestInvalid)?;
    if adapter
        .snapshot
        .typed_relationships
        .iter()
        .any(|record| !record.is_valid())
    {
        return Err(DispatchError::RequestInvalid);
    }
    let mut rows = adapter
        .snapshot
        .typed_relationships
        .iter()
        .filter(|record| relationship_matches(record, request))
        .cloned()
        .collect::<Vec<_>>();
    rows.sort_by(|left, right| {
        left.relationship_kind
            .cmp(&right.relationship_kind)
            .then_with(|| {
                neighbor_key(left, &request.selector).cmp(&neighbor_key(right, &request.selector))
            })
            .then_with(|| left.assertion_id.cmp(&right.assertion_id))
            .then_with(|| left.assertion_revision.cmp(&right.assertion_revision))
    });
    rows.truncate(usize::from(request.limit));
    Ok(ToolResponse::RelationshipNeighborsV3(
        RelationshipNeighborsResponseV3 {
            schema_version: "relationship.neighbors.response.v3".to_owned(),
            query_digest,
            neighbors: rows.into_iter().map(wire_neighbor).collect(),
        },
    ))
}

fn valid_request(request: &RelationshipNeighborsRequestV3) -> bool {
    request.selector.is_valid()
        && (1..=50).contains(&request.limit)
        && request.as_of.as_ref().is_none_or(|date| valid_date(date))
        && request.relationship_kinds.len() <= 9
        && request
            .relationship_kinds
            .windows(2)
            .all(|window| window[0] < window[1])
}

fn relationship_matches(
    record: &RelationshipNeighborRecordV3,
    request: &RelationshipNeighborsRequestV3,
) -> bool {
    let endpoint_matches =
        record.subject.matches(&request.selector) || record.object.matches(&request.selector);
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

fn neighbor_key(
    record: &RelationshipNeighborRecordV3,
    selector: &RelationshipEndpointSelectorV3,
) -> String {
    if record.subject.matches(selector) {
        record.object.stable_key()
    } else {
        record.subject.stable_key()
    }
}

fn wire_neighbor(record: RelationshipNeighborRecordV3) -> RelationshipNeighborV3 {
    RelationshipNeighborV3 {
        subject: record.subject.wire_endpoint(),
        object: record.object.wire_endpoint(),
        relationship_kind: record.relationship_kind,
        assertion_id: record.assertion_id,
        assertion_revision: record.assertion_revision,
        assertion_digest: record.assertion_digest,
        valid_from: record.valid_from,
        valid_to: record.valid_to,
        evidence_set_digest: record.evidence_set_digest,
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

fn lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
#[path = "runtime_relationship_adapter_tests.rs"]
mod tests;
