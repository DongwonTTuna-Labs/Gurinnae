use super::super::super::sha256;
use super::super::{Failure, ProviderTurnIdentity, database};
use super::{TypedRelationshipRequest, invalid};
use gurine_agent_orchestration::runtime::{
    RelationshipEndpointRecordV3, RelationshipKindV3, RelationshipNeighborRecordV3,
};
use gurine_domain::relationship_graph::{
    ListRelationshipNeighborsV3, RelationshipGraphAgentRunId, RelationshipGraphDatasetSnapshotId,
    RelationshipGraphEndpointId, RelationshipGraphEndpointV3, RelationshipKindV2,
    RelationshipNeighborV3, Sha256Digest,
};
use gurine_persistence_postgres::relationship_graph::RelationshipGraphRepository;
use serde_json::{Map, Value};
use sqlx::{Postgres, Transaction};
use time::{Date, Month};
use uuid::Uuid;

pub(super) async fn load(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    dataset_snapshot_id: Uuid,
    request: TypedRelationshipRequest,
) -> Result<Vec<RelationshipNeighborRecordV3>, Failure> {
    let query = domain_query(
        turn.run_id,
        dataset_snapshot_id,
        &turn.input_snapshot_sha256,
        request,
    )?;
    let expected_query_digest = sha256(&query.request_canonical);
    let result = RelationshipGraphRepository::list_neighbors(&mut **executor, &query)
        .await
        .map_err(database)?;
    if result.query_digest.as_str() != expected_query_digest
        || result.neighbors.len() > usize::from(query.limit)
    {
        return Err(invalid("relationshipVerification"));
    }
    result.neighbors.into_iter().map(agent_neighbor).collect()
}

fn domain_query(
    run_id: Uuid,
    snapshot_id: Uuid,
    snapshot_sha256: &str,
    request: TypedRelationshipRequest,
) -> Result<ListRelationshipNeighborsV3, Failure> {
    let value = serde_json::from_slice::<Value>(&request.canonical)
        .map_err(|_| invalid("relationshipRequestCanonical"))?;
    let object = exact_object(
        &value,
        &[
            "schemaVersion",
            "runId",
            "inputSnapshotId",
            "inputSnapshotSha256",
            "selector",
            "relationshipKinds",
            "asOf",
            "limit",
        ],
        "relationshipRequest",
    )?;
    let wire_limit = object
        .get("limit")
        .and_then(Value::as_u64)
        .and_then(|value| u8::try_from(value).ok())
        .ok_or_else(|| invalid("relationshipLimit"))?;
    if string(object, "schemaVersion")? != "relationship.neighbors.request.v3"
        || uuid(object, "runId")? != run_id
        || uuid(object, "inputSnapshotId")? != snapshot_id
        || string(object, "inputSnapshotSha256")? != snapshot_sha256
        || i64::from(wire_limit) != request.limit
    {
        return Err(invalid("relationshipBinding"));
    }
    let query = ListRelationshipNeighborsV3 {
        agent_run_id: RelationshipGraphAgentRunId::new(run_id).map_err(|_| invalid("runId"))?,
        snapshot_id: RelationshipGraphDatasetSnapshotId::new(snapshot_id)
            .map_err(|_| invalid("inputSnapshotId"))?,
        snapshot_generation: u64::try_from(request.snapshot_generation)
            .map_err(|_| invalid("snapshotGeneration"))?,
        snapshot_sha256: Sha256Digest::new(snapshot_sha256)
            .map_err(|_| invalid("inputSnapshotSha256"))?,
        selector: selector(object.get("selector"))?,
        relationship_kinds: relationship_kinds(object.get("relationshipKinds"))?,
        as_of: optional_date(object.get("asOf"))?,
        limit: wire_limit,
        request_canonical: request.canonical,
    };
    query
        .validate()
        .map_err(|_| invalid("relationshipRequest"))?;
    Ok(query)
}

fn selector(value: Option<&Value>) -> Result<RelationshipGraphEndpointV3, Failure> {
    let object = value
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("selector"))?;
    match string(object, "kind")? {
        "PERSON" => {
            exact_keys(object, &["kind", "personNodeRef"], "selector")?;
            Ok(RelationshipGraphEndpointV3::Person {
                person_node_ref: Sha256Digest::new(string(object, "personNodeRef")?)
                    .map_err(|_| invalid("selector.personNodeRef"))?,
            })
        }
        kind @ ("SUPPLIER" | "AGENCY" | "PROCUREMENT_NOTICE" | "SANCTION") => {
            exact_keys(object, &["kind", "endpointId"], "selector")?;
            let endpoint_id = RelationshipGraphEndpointId::new(uuid(object, "endpointId")?)
                .map_err(|_| invalid("selector.endpointId"))?;
            Ok(match kind {
                "SUPPLIER" => RelationshipGraphEndpointV3::Supplier { endpoint_id },
                "AGENCY" => RelationshipGraphEndpointV3::Agency { endpoint_id },
                "PROCUREMENT_NOTICE" => {
                    RelationshipGraphEndpointV3::ProcurementNotice { endpoint_id }
                }
                _ => RelationshipGraphEndpointV3::Sanction { endpoint_id },
            })
        }
        _ => Err(invalid("selector.kind")),
    }
}

fn relationship_kinds(value: Option<&Value>) -> Result<Vec<RelationshipKindV2>, Failure> {
    value
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("relationshipKinds"))?
        .iter()
        .map(|item| {
            let text = item.as_str().ok_or_else(|| invalid("relationshipKinds"))?;
            match text {
                "OWNERSHIP" => Ok(RelationshipKindV2::Ownership),
                "BENEFICIAL_OWNERSHIP" => Ok(RelationshipKindV2::BeneficialOwnership),
                "CONTROL" => Ok(RelationshipKindV2::Control),
                "MANAGEMENT_ROLE" => Ok(RelationshipKindV2::ManagementRole),
                "LEGAL_REPRESENTATIVE" => Ok(RelationshipKindV2::LegalRepresentative),
                "CONTRACTUAL_RELATIONSHIP" => Ok(RelationshipKindV2::ContractualRelationship),
                "BID_PARTICIPATION" => Ok(RelationshipKindV2::BidParticipation),
                "SANCTION" => Ok(RelationshipKindV2::Sanction),
                "FORMER_OFFICIAL_ROLE" => Ok(RelationshipKindV2::FormerOfficialRole),
                _ => Err(invalid("relationshipKinds")),
            }
        })
        .collect()
}

fn agent_neighbor(value: RelationshipNeighborV3) -> Result<RelationshipNeighborRecordV3, Failure> {
    Ok(RelationshipNeighborRecordV3 {
        subject: agent_endpoint(value.subject),
        object: agent_endpoint(value.object),
        relationship_kind: agent_kind(value.relationship_kind),
        assertion_id: value.assertion_id.value(),
        assertion_revision: value.assertion_revision,
        assertion_digest: value.assertion_digest.as_str().to_owned(),
        valid_from: value.valid_from.map(|date| date.to_string()),
        valid_to: value.valid_to.map(|date| date.to_string()),
        evidence_set_digest: value.evidence_set_digest.as_str().to_owned(),
        subject_source_use_id: value.subject_source_use_id.value(),
        object_source_use_id: value.object_source_use_id.value(),
    })
}

fn agent_endpoint(value: RelationshipGraphEndpointV3) -> RelationshipEndpointRecordV3 {
    match value {
        RelationshipGraphEndpointV3::Supplier { endpoint_id } => {
            RelationshipEndpointRecordV3::Supplier {
                endpoint_id: endpoint_id.value(),
            }
        }
        RelationshipGraphEndpointV3::Person { person_node_ref } => {
            RelationshipEndpointRecordV3::Person {
                person_node_ref: person_node_ref.as_str().to_owned(),
            }
        }
        RelationshipGraphEndpointV3::Agency { endpoint_id } => {
            RelationshipEndpointRecordV3::Agency {
                endpoint_id: endpoint_id.value(),
            }
        }
        RelationshipGraphEndpointV3::ProcurementNotice { endpoint_id } => {
            RelationshipEndpointRecordV3::ProcurementNotice {
                endpoint_id: endpoint_id.value(),
            }
        }
        RelationshipGraphEndpointV3::Sanction { endpoint_id } => {
            RelationshipEndpointRecordV3::Sanction {
                endpoint_id: endpoint_id.value(),
            }
        }
    }
}

fn agent_kind(value: RelationshipKindV2) -> RelationshipKindV3 {
    match value {
        RelationshipKindV2::Ownership => RelationshipKindV3::Ownership,
        RelationshipKindV2::BeneficialOwnership => RelationshipKindV3::BeneficialOwnership,
        RelationshipKindV2::Control => RelationshipKindV3::Control,
        RelationshipKindV2::ManagementRole => RelationshipKindV3::ManagementRole,
        RelationshipKindV2::LegalRepresentative => RelationshipKindV3::LegalRepresentative,
        RelationshipKindV2::ContractualRelationship => RelationshipKindV3::ContractualRelationship,
        RelationshipKindV2::BidParticipation => RelationshipKindV3::BidParticipation,
        RelationshipKindV2::Sanction => RelationshipKindV3::Sanction,
        RelationshipKindV2::FormerOfficialRole => RelationshipKindV3::FormerOfficialRole,
    }
}

fn optional_date(value: Option<&Value>) -> Result<Option<Date>, Failure> {
    match value {
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => parse_date(value).map(Some).ok_or_else(|| invalid("asOf")),
        _ => Err(invalid("asOf")),
    }
}

fn parse_date(value: &str) -> Option<Date> {
    let [year, month, day] = <[&str; 3]>::try_from(value.split('-').collect::<Vec<_>>()).ok()?;
    let date = Date::from_calendar_date(
        year.parse().ok()?,
        Month::try_from(month.parse::<u8>().ok()?).ok()?,
        day.parse().ok()?,
    )
    .ok()?;
    (date.to_string() == value).then_some(date)
}

fn exact_object<'a>(
    value: &'a Value,
    keys: &[&str],
    field: &str,
) -> Result<&'a Map<String, Value>, Failure> {
    let object = value.as_object().ok_or_else(|| invalid(field))?;
    exact_keys(object, keys, field)?;
    Ok(object)
}

fn exact_keys(object: &Map<String, Value>, keys: &[&str], field: &str) -> Result<(), Failure> {
    if object.len() == keys.len() && keys.iter().all(|key| object.contains_key(*key)) {
        Ok(())
    } else {
        Err(invalid(field))
    }
}

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(key))
}

fn uuid(object: &Map<String, Value>, key: &str) -> Result<Uuid, Failure> {
    Uuid::parse_str(string(object, key)?).map_err(|_| invalid(key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use gurine_domain::relationship_graph::RelationshipEndpointKindV2;
    use serde_json::json;

    #[test]
    fn person_selector_rejects_contextual_or_family_fields() {
        let value = json!({
            "kind":"PERSON", "personNodeRef":"a".repeat(64), "familyRelation":"부"
        });
        assert!(selector(Some(&value)).is_err());
    }

    #[test]
    fn endpoint_mapping_keeps_person_opaque() {
        let endpoint = agent_endpoint(RelationshipGraphEndpointV3::Person {
            person_node_ref: Sha256Digest::new("b".repeat(64)).unwrap(),
        });
        assert_eq!(
            endpoint,
            RelationshipEndpointRecordV3::Person {
                person_node_ref: "b".repeat(64)
            }
        );
    }

    #[test]
    fn date_parser_is_calendar_strict() {
        assert!(parse_date("2026-02-28").is_some());
        assert!(parse_date("2026-02-30").is_none());
        assert!(parse_date("2026-2-8").is_none());
    }

    #[test]
    fn endpoint_kind_catalog_stays_at_five() {
        let kinds = [
            RelationshipEndpointKindV2::Supplier,
            RelationshipEndpointKindV2::Person,
            RelationshipEndpointKindV2::Agency,
            RelationshipEndpointKindV2::ProcurementNotice,
            RelationshipEndpointKindV2::Sanction,
        ];
        assert_eq!(kinds.len(), 5);
    }
}
