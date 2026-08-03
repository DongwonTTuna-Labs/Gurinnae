use super::*;

fn record(
    relationship_kind: RelationshipKindV3,
    subject: RelationshipEndpointRecordV3,
    object: RelationshipEndpointRecordV3,
) -> RelationshipNeighborRecordV3 {
    RelationshipNeighborRecordV3 {
        subject,
        object,
        relationship_kind,
        assertion_id: Uuid::from_u128(20),
        assertion_revision: 2,
        assertion_digest: "c".repeat(64),
        valid_from: None,
        valid_to: None,
        evidence_set_digest: "d".repeat(64),
        subject_source_use_id: Uuid::from_u128(21),
        object_source_use_id: Uuid::from_u128(22),
    }
}

fn supplier(id: u128) -> RelationshipEndpointRecordV3 {
    RelationshipEndpointRecordV3::Supplier {
        endpoint_id: Uuid::from_u128(id),
    }
}

fn person() -> RelationshipEndpointRecordV3 {
    RelationshipEndpointRecordV3::Person {
        person_node_ref: "a".repeat(64),
    }
}

#[test]
fn person_context_never_crosses_the_wire_adapter() {
    let record = record(RelationshipKindV3::ManagementRole, person(), supplier(1));
    let text = serde_json::to_value(wire_neighbor(record))
        .ok()
        .map(|value| value.to_string())
        .unwrap_or_default();
    for forbidden in [
        "contextualName",
        "roleTitle",
        "sourceLocator",
        "identifierDigest",
    ] {
        assert!(!text.contains(forbidden), "wire leaked {forbidden}");
    }
    assert!(text.contains("personNodeRef"));
}

#[test]
fn endpoint_pair_catalog_matches_the_database_check() {
    let valid = [
        record(RelationshipKindV3::Ownership, supplier(1), supplier(2)),
        record(
            RelationshipKindV3::BeneficialOwnership,
            supplier(1),
            supplier(2),
        ),
        record(RelationshipKindV3::Control, supplier(1), supplier(2)),
        record(
            RelationshipKindV3::ContractualRelationship,
            supplier(1),
            supplier(2),
        ),
        record(RelationshipKindV3::ManagementRole, person(), supplier(2)),
        record(
            RelationshipKindV3::LegalRepresentative,
            person(),
            supplier(2),
        ),
        record(
            RelationshipKindV3::BidParticipation,
            supplier(1),
            RelationshipEndpointRecordV3::ProcurementNotice {
                endpoint_id: Uuid::from_u128(3),
            },
        ),
        record(
            RelationshipKindV3::Sanction,
            supplier(1),
            RelationshipEndpointRecordV3::Sanction {
                endpoint_id: Uuid::from_u128(4),
            },
        ),
        record(
            RelationshipKindV3::FormerOfficialRole,
            person(),
            RelationshipEndpointRecordV3::Agency {
                endpoint_id: Uuid::from_u128(5),
            },
        ),
    ];
    assert!(valid.iter().all(RelationshipNeighborRecordV3::is_valid));
    assert!(
        !record(
            RelationshipKindV3::BidParticipation,
            person(),
            RelationshipEndpointRecordV3::Sanction {
                endpoint_id: Uuid::from_u128(6),
            },
        )
        .is_valid()
    );
}

#[test]
fn response_uses_the_database_validated_exact_request_digest() {
    let binding = SnapshotBinding {
        run_id: Uuid::from_u128(30),
        input_snapshot_id: Uuid::from_u128(31),
        input_snapshot_sha256: "b".repeat(64),
    };
    let query_digest = "9".repeat(64);
    let request = RelationshipNeighborsRequestV3 {
        binding: binding.clone(),
        selector: RelationshipEndpointSelectorV3::Person {
            person_node_ref: "a".repeat(64),
        },
        relationship_kinds: vec![RelationshipKindV3::ManagementRole],
        as_of: Some("2026-01-01".to_owned()),
        limit: 7,
    };
    let adapter = SnapshotAdapter {
        id: ToolId::RelationshipNeighbors,
        snapshot: ToolSnapshot {
            binding,
            evidence: Vec::new(),
            responses: Vec::new(),
            comparables: Vec::new(),
            entities: Vec::new(),
            rules: Vec::new(),
            contracts: Vec::new(),
            supplier_profiles: Vec::new(),
            agency_profiles: Vec::new(),
            relationships: Vec::new(),
            typed_relationships: vec![record(
                RelationshipKindV3::ManagementRole,
                person(),
                supplier(1),
            )],
            typed_relationship_query_digest: Some(query_digest.clone()),
            source_artifacts: Vec::new(),
        },
    };
    let response_digest = match relationship_neighbors_v3(&adapter, &request) {
        Ok(ToolResponse::RelationshipNeighborsV3(response)) => Some(response.query_digest),
        _ => None,
    };
    assert_eq!(response_digest.as_deref(), Some(query_digest.as_str()));

    let mut missing = adapter;
    missing.snapshot.typed_relationship_query_digest = None;
    assert_eq!(
        relationship_neighbors_v3(&missing, &request),
        Err(DispatchError::RequestInvalid)
    );
}
