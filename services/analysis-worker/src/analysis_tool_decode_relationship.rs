fn decode_relationship_neighbors(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    match value.get("schemaVersion").and_then(Value::as_str) {
        Some("relationship.neighbors.request.v2") => decode_relationship_neighbors_v2(value),
        Some("relationship.neighbors.request.v3") => decode_relationship_neighbors_v3(value),
        _ => Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "schemaVersion".into(),
        )),
    }
}

fn decode_relationship_neighbors_v2(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{
        RelationshipKind, RelationshipNeighborsRequest, ToolRequest,
    };
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "supplierId",
        "relationshipKinds",
        "asOf",
        "limit",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(
        value,
        "relationship.neighbors.request.v2",
        &binding,
        &fields,
    )?;
    require_keys(&object, &fields[4..])?;
    let raw_kinds = string_array(&object, "relationshipKinds", 6, 64)?;
    let relationship_kinds = raw_kinds
        .iter()
        .map(|kind| match kind.as_str() {
            "OWNERSHIP" => Ok(RelationshipKind::Ownership),
            "BENEFICIAL_OWNERSHIP" => Ok(RelationshipKind::BeneficialOwnership),
            "CONTROL" => Ok(RelationshipKind::Control),
            "MANAGEMENT_ROLE" => Ok(RelationshipKind::ManagementRole),
            "LEGAL_REPRESENTATIVE" => Ok(RelationshipKind::LegalRepresentative),
            "CONTRACTUAL_RELATIONSHIP" => Ok(RelationshipKind::ContractualRelationship),
            _ => Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "relationshipKinds".into(),
            )),
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ToolRequest::RelationshipNeighbors(
        RelationshipNeighborsRequest {
            binding,
            supplier_id: required_uuid(&object, "supplierId")?,
            relationship_kinds,
            as_of: optional_date(&object, "asOf")?,
            limit: bounded_u8(&object, "limit", 1, 50)?,
        },
    ))
}

fn decode_relationship_neighbors_v3(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{
        RelationshipKindV3, RelationshipNeighborsRequestV3, ToolRequest,
    };
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "selector",
        "relationshipKinds",
        "asOf",
        "limit",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(
        value,
        "relationship.neighbors.request.v3",
        &binding,
        &fields,
    )?;
    require_keys(&object, &fields[4..])?;
    let selector = decode_relationship_selector_v3(&object)?;
    let raw_kinds = string_array(&object, "relationshipKinds", 9, 64)?;
    let relationship_kinds = raw_kinds
        .iter()
        .map(|kind| match kind.as_str() {
            "OWNERSHIP" => Ok(RelationshipKindV3::Ownership),
            "BENEFICIAL_OWNERSHIP" => Ok(RelationshipKindV3::BeneficialOwnership),
            "CONTROL" => Ok(RelationshipKindV3::Control),
            "MANAGEMENT_ROLE" => Ok(RelationshipKindV3::ManagementRole),
            "LEGAL_REPRESENTATIVE" => Ok(RelationshipKindV3::LegalRepresentative),
            "CONTRACTUAL_RELATIONSHIP" => Ok(RelationshipKindV3::ContractualRelationship),
            "BID_PARTICIPATION" => Ok(RelationshipKindV3::BidParticipation),
            "SANCTION" => Ok(RelationshipKindV3::Sanction),
            "FORMER_OFFICIAL_ROLE" => Ok(RelationshipKindV3::FormerOfficialRole),
            _ => Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "relationshipKinds".into(),
            )),
        })
        .collect::<Result<Vec<_>, _>>()?;
    if !relationship_kinds
        .windows(2)
        .all(|window| window[0] < window[1])
    {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "relationshipKinds".into(),
        ));
    }
    Ok(ToolRequest::RelationshipNeighborsV3(
        RelationshipNeighborsRequestV3 {
            binding,
            selector,
            relationship_kinds,
            as_of: optional_date(&object, "asOf")?,
            limit: bounded_u8(&object, "limit", 1, 50)?,
        },
    ))
}

fn decode_relationship_selector_v3(
    object: &serde_json::Map<String, Value>,
) -> Result<gurine_agent_orchestration::runtime::RelationshipEndpointSelectorV3, Failure> {
    use gurine_agent_orchestration::runtime::RelationshipEndpointSelectorV3;
    let selector = object
        .get("selector")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "selector".into()))?;
    let kind = required_string(selector, "kind")?;
    match kind.as_str() {
        "PERSON" => {
            exact_keys(selector, &["kind", "personNodeRef"], "selector")?;
            let node_ref = required_string(selector, "personNodeRef")?;
            if !is_sha256_text(&node_ref) {
                return Err(Failure::Terminal(
                    "PROVIDER_TOOL_CALL_INVALID",
                    "selector.personNodeRef".into(),
                ));
            }
            Ok(RelationshipEndpointSelectorV3::Person {
                person_node_ref: node_ref,
            })
        }
        "SUPPLIER" | "AGENCY" | "PROCUREMENT_NOTICE" | "SANCTION" => {
            exact_keys(selector, &["kind", "endpointId"], "selector")?;
            let endpoint_id = required_uuid(selector, "endpointId")?;
            match kind.as_str() {
                "SUPPLIER" => Ok(RelationshipEndpointSelectorV3::Supplier { endpoint_id }),
                "AGENCY" => Ok(RelationshipEndpointSelectorV3::Agency { endpoint_id }),
                "PROCUREMENT_NOTICE" => {
                    Ok(RelationshipEndpointSelectorV3::ProcurementNotice { endpoint_id })
                }
                "SANCTION" => Ok(RelationshipEndpointSelectorV3::Sanction { endpoint_id }),
                _ => Err(Failure::Terminal(
                    "PROVIDER_TOOL_CALL_INVALID",
                    "selector.kind".into(),
                )),
            }
        }
        _ => Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "selector.kind".into(),
        )),
    }
}

fn exact_keys(
    object: &serde_json::Map<String, Value>,
    expected: &[&str],
    field: &str,
) -> Result<(), Failure> {
    if object.len() != expected.len() || object.keys().any(|key| !expected.contains(&key.as_str()))
    {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            field.to_owned(),
        ));
    }
    require_keys(object, expected)
}

#[cfg(test)]
mod relationship_v3_decode_tests {
    use super::*;
    use serde_json::json;

    fn request(selector: Value, relationship_kinds: Value) -> Value {
        let run_id = Uuid::from_u128(1);
        let snapshot_id = Uuid::from_u128(2);
        json!({
            "schemaVersion": "relationship.neighbors.request.v3",
            "runId": run_id,
            "inputSnapshotId": snapshot_id,
            "inputSnapshotSha256": "a".repeat(64),
            "selector": selector,
            "relationshipKinds": relationship_kinds,
            "asOf": null,
            "limit": 50,
            "binding": {
                "run_id": run_id,
                "input_snapshot_id": snapshot_id,
                "input_snapshot_sha256": "a".repeat(64),
            },
        })
    }

    #[test]
    fn typed_request_accepts_exact_five_endpoint_and_nine_kind_contract() {
        let kinds = json!([
            "OWNERSHIP",
            "BENEFICIAL_OWNERSHIP",
            "CONTROL",
            "MANAGEMENT_ROLE",
            "LEGAL_REPRESENTATIVE",
            "CONTRACTUAL_RELATIONSHIP",
            "BID_PARTICIPATION",
            "SANCTION",
            "FORMER_OFFICIAL_ROLE",
        ]);
        for selector in [
            json!({"kind":"SUPPLIER","endpointId":Uuid::from_u128(3)}),
            json!({"kind":"PERSON","personNodeRef":"b".repeat(64)}),
            json!({"kind":"AGENCY","endpointId":Uuid::from_u128(4)}),
            json!({"kind":"PROCUREMENT_NOTICE","endpointId":Uuid::from_u128(5)}),
            json!({"kind":"SANCTION","endpointId":Uuid::from_u128(6)}),
        ] {
            assert!(decode_relationship_neighbors_v3(request(selector, kinds.clone())).is_ok());
        }
    }

    #[test]
    fn typed_request_rejects_unsorted_duplicate_or_family_kinds() {
        for kinds in [
            json!(["CONTROL", "OWNERSHIP"]),
            json!(["OWNERSHIP", "OWNERSHIP"]),
            json!(["FAMILY_RELATIONSHIP"]),
        ] {
            let value = request(
                json!({"kind":"SUPPLIER","endpointId":Uuid::from_u128(3)}),
                kinds,
            );
            assert!(decode_relationship_neighbors_v3(value).is_err());
        }
    }

    #[test]
    fn person_selector_rejects_stable_digest_and_context_fields() {
        for selector in [
            json!({"kind":"PERSON","personNodeDigest":"b".repeat(64)}),
            json!({"kind":"PERSON","personNodeRef":"b".repeat(64),"contextualName":"금지"}),
            json!({"kind":"PERSON","personNodeRef":"B".repeat(64)}),
            json!({"kind":"PERSON","personNodeRef":"b".repeat(64),"identifierDigest":"c".repeat(64)}),
        ] {
            assert!(decode_relationship_neighbors_v3(request(selector, json!([]))).is_err());
        }
    }

    #[test]
    fn typed_request_rejects_null_missing_unknown_and_binding_drift() {
        let selector = json!({"kind":"AGENCY","endpointId":Uuid::from_u128(4)});
        let mut null_schema = request(selector.clone(), json!([]));
        null_schema["schemaVersion"] = Value::Null;
        assert!(decode_relationship_neighbors_v3(null_schema).is_err());

        let mut missing_schema = request(selector.clone(), json!([]));
        if let Some(object) = missing_schema.as_object_mut() {
            object.remove("schemaVersion");
        }
        assert!(decode_relationship_neighbors_v3(missing_schema).is_err());

        let mut unknown = request(selector.clone(), json!([]));
        unknown["score"] = json!(0.99);
        assert!(decode_relationship_neighbors_v3(unknown).is_err());

        let mut binding_drift = request(selector, json!([]));
        binding_drift["binding"]["run_id"] = json!(Uuid::from_u128(99));
        assert!(decode_relationship_neighbors_v3(binding_drift).is_err());
    }
}
