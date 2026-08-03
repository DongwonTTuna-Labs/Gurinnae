use gurine_domain::relationship_graph::*;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub(super) fn endpoint_request(command: &RecordRelationshipGraphEndpointV2) -> Value {
    let (contextual_name, role_title, entity_id, entity_revision, entity_digest) =
        match &command.identity {
            RelationshipEndpointIdentityV2::Person {
                contextual_name,
                role_title,
            } => (
                Some(contextual_name.as_str()),
                Some(role_title.as_str()),
                None,
                None,
                None,
            ),
            RelationshipEndpointIdentityV2::Entity {
                entity_id,
                entity_revision,
                entity_digest,
            } => (
                None,
                None,
                Some(entity_id.value()),
                Some(*entity_revision),
                Some(entity_digest.as_str()),
            ),
        };
    json!({
        "schemaVersion": "typed-relationship-endpoint.record.request.v2",
        "endpointKind": command.kind.as_str(),
        "contextualName": contextual_name,
        "roleTitle": role_title,
        "sourceKind": command.source_kind,
        "sourceLocator": command.source_locator,
        "identifierDigest": command.identifier_digest.as_str(),
        "entityId": entity_id,
        "entityRevision": entity_revision,
        "entityDigest": entity_digest,
        "sourceDocument": {
            "id": command.source.document_id.value(),
            "assetId": command.source.asset_id.value(),
            "assetRevision": command.source.asset_revision,
            "contentSha256": command.source.content_sha256.as_str(),
            "parserRunId": command.source.parser_run_id.value(),
            "parsedRecordId": command.source.parsed_record_id.value(),
            "parserVersion": command.source.parser_version,
            "parsedPayloadSha256": command.source.parsed_payload_sha256.as_str(),
        },
        "operationId": "recordTypedRelationshipEndpoint",
    })
}

pub(super) fn assertion_request(command: &RecordRelationshipGraphAssertionV2) -> Value {
    let evidence = command
        .evidence
        .iter()
        .map(evidence_value)
        .collect::<Vec<_>>();
    json!({
        "schemaVersion": "typed-relationship-assertion.record.request.v2",
        "assertionId": command.assertion_id.value(),
        "relationshipKind": command.relationship_kind.as_str(),
        "sourceKind": command.source_kind,
        "sourceLocator": command.source_locator,
        "subjectEndpoint": endpoint_ref_value(&command.subject),
        "objectEndpoint": endpoint_ref_value(&command.object),
        "validFrom": command.valid_from.map(|date| date.to_string()),
        "validTo": command.valid_to.map(|date| date.to_string()),
        "departedOn": command.departed_on.map(|date| date.to_string()),
        "validityCoverageStatus": command.coverage.as_str(),
        "evidence": evidence,
        "proposedActor": actor_value(&command.proposed_actor),
        "operationId": "recordTypedRelationshipAssertion",
    })
}

fn evidence_value(evidence: &RelationshipGraphAssertionEvidenceV2) -> Value {
    let (document, source_use) = match &evidence.source {
        RelationshipEvidenceSourceV2::SourceDocument {
            document_id,
            asset_id,
            asset_revision,
            content_sha256,
        } => (
            Some(json!({
                "id": document_id.value(), "assetId": asset_id.value(),
                "assetRevision": asset_revision, "contentSha256": content_sha256.as_str(),
            })),
            None,
        ),
        RelationshipEvidenceSourceV2::SourceUse {
            agent_run_id,
            source_use_id,
            source_use_sha256,
        } => (
            None,
            Some(json!({
                "agentRunId": agent_run_id.value(), "sourceUseId": source_use_id.value(),
                "sourceUseSha256": source_use_sha256.as_str(),
            })),
        ),
    };
    json!({
        "evidenceId": evidence.evidence_id.value(),
        "evidenceVersion": evidence.evidence_version,
        "evidenceDigest": evidence.evidence_digest.as_str(),
        "sourceDocument": document,
        "sourceUse": source_use,
        "locatorDigest": evidence.locator_digest.as_str(),
    })
}

fn endpoint_ref_value(endpoint: &RelationshipGraphEndpointRefV2) -> Value {
    json!({
        "endpointId": endpoint.endpoint_id.value(),
        "endpointKind": endpoint.endpoint_kind.as_str(),
        "endpointDigest": endpoint.endpoint_digest.as_str(),
    })
}

fn actor_value(actor: &RelationshipGraphActorV2) -> Value {
    match actor {
        RelationshipGraphActorV2::ServiceIngestWorker => {
            json!({"type":"SERVICE","id":"ingest-worker"})
        }
        RelationshipGraphActorV2::Human(id) => json!({"type":"HUMAN","id":id.value()}),
    }
}

pub(super) fn decision_request(command: &DecideRelationshipGraphAssertionV2) -> Value {
    json!({
        "schemaVersion": "typed-relationship-assertion.decision.request.v2",
        "decision": command.decision.as_str(),
        "reasonCode": command.reason_code,
        "reason": command.reason,
        "actorUserId": command.actor_user_id.value(),
        "operationId": "decideTypedRelationshipAssertion",
    })
}

pub(super) fn neighbors_request(command: &ListRelationshipNeighborsV3) -> Value {
    json!({
        "schemaVersion": "relationship.neighbors.request.v3",
        "runId": command.agent_run_id.value(),
        "inputSnapshotId": command.snapshot_id.value(),
        "inputSnapshotSha256": command.snapshot_sha256.as_str(),
        "selector": command.selector,
        "relationshipKinds": command.relationship_kinds.iter().map(|kind| kind.as_str()).collect::<Vec<_>>(),
        "asOf": command.as_of.map(|date| date.to_string()),
        "limit": command.limit,
    })
}

pub(super) fn canonical_json(value: &Value) -> Result<Vec<u8>, serde_json::Error> {
    fn append(value: &Value, output: &mut Vec<u8>) -> Result<(), serde_json::Error> {
        match value {
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {
                serde_json::to_writer(output, value)
            }
            Value::Array(values) => {
                output.push(b'[');
                for (index, item) in values.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    append(item, output)?;
                }
                output.push(b']');
                Ok(())
            }
            Value::Object(values) => {
                output.push(b'{');
                let mut keys = values.keys().collect::<Vec<_>>();
                keys.sort();
                for (index, key) in keys.into_iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    serde_json::to_writer(&mut *output, key)?;
                    output.push(b':');
                    append(&values[key], output)?;
                }
                output.push(b'}');
                Ok(())
            }
        }
    }
    let mut output = Vec::new();
    append(value, &mut output)?;
    Ok(output)
}

pub(super) fn hex_digest(value: &[u8]) -> String {
    format!("{:x}", Sha256::digest(value))
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn canonical_request_is_stable_and_contains_no_person_context() {
        let command = ListRelationshipNeighborsV3 {
            agent_run_id: RelationshipGraphAgentRunId::new(Uuid::from_u128(1)).unwrap(),
            snapshot_id: RelationshipGraphDatasetSnapshotId::new(Uuid::from_u128(2)).unwrap(),
            snapshot_generation: 3,
            snapshot_sha256: Sha256Digest::new("a".repeat(64)).unwrap(),
            selector: RelationshipGraphEndpointV3::Person {
                person_node_ref: Sha256Digest::new("b".repeat(64)).unwrap(),
            },
            relationship_kinds: vec![RelationshipKindV2::ManagementRole],
            as_of: None,
            limit: 5,
            request_canonical: vec![b'{', b'}'],
        };
        let bytes = canonical_json(&neighbors_request(&command)).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert!(text.contains("\"personNodeRef\""));
        assert!(!text.contains("contextualName"));
        assert!(!text.contains("roleTitle"));
        assert_eq!(hex_digest(text.as_bytes()).len(), 64);
    }
}
