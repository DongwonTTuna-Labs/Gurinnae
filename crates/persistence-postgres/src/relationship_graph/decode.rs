use super::{AssertionRow, DecisionRow, NeighborRow};
use gurine_domain::relationship_graph::*;
use serde_json::Value;
use uuid::Uuid;

pub(super) fn decode_endpoint_response(
    value: Value,
) -> Result<RelationshipGraphEndpointV2, sqlx::Error> {
    let object = exact_object(
        &value,
        &[
            "schemaVersion",
            "endpointId",
            "endpointKind",
            "endpointDigest",
            "identityResolutionStatus",
            "replayed",
        ],
    )?;
    if string(object, "schemaVersion")? != "typed-relationship-endpoint.record.response.v2" {
        return Err(domain_decode(RelationshipGraphError::InvalidState));
    }
    let endpoint = RelationshipGraphEndpointV2 {
        endpoint_id: RelationshipGraphEndpointId::new(uuid(object, "endpointId")?)
            .map_err(domain_decode)?,
        endpoint_kind: endpoint_kind(string(object, "endpointKind")?)?,
        endpoint_digest: digest(string(object, "endpointDigest")?)?,
        identity_resolution_status: identity_status(string(object, "identityResolutionStatus")?)?,
        replayed: boolean(object, "replayed")?,
    };
    endpoint.validate().map_err(domain_decode)?;
    Ok(endpoint)
}

pub(super) fn assertion_from_row(
    row: AssertionRow,
) -> Result<RelationshipGraphAssertionV2, sqlx::Error> {
    let assertion = RelationshipGraphAssertionV2 {
        assertion_id: RelationshipGraphAssertionId::new(row.assertion_id).map_err(domain_decode)?,
        assertion_revision: positive_revision(row.assertion_revision)?,
        assertion_digest: digest(&row.assertion_digest)?,
        receipt_sha256: digest(&row.receipt_sha256)?,
        verification_status: verification_status(&row.verification_status)?,
        public_use_status: public_status(&row.public_use_status)?,
        replayed: row.replayed,
    };
    assertion.validate().map_err(domain_decode)?;
    Ok(assertion)
}

pub(super) fn decision_from_row(
    row: DecisionRow,
) -> Result<RelationshipGraphVerificationDecisionV2, sqlx::Error> {
    let assertion = assertion_from_row(AssertionRow {
        assertion_id: row.assertion_id,
        assertion_revision: row.assertion_revision,
        assertion_digest: row.assertion_digest,
        receipt_sha256: row.receipt_sha256,
        verification_status: row.verification_status,
        public_use_status: row.public_use_status,
        disposition: "DECIDED".to_owned(),
        replayed: row.replayed,
    })?;
    let decision = RelationshipGraphVerificationDecisionV2 {
        decision_id: RelationshipGraphDecisionId::new(row.decision_id).map_err(domain_decode)?,
        assertion,
    };
    decision.validate().map_err(domain_decode)?;
    Ok(decision)
}

pub(super) fn neighbor_from_row(
    row: NeighborRow,
    expected: &Sha256Digest,
) -> Result<RelationshipNeighborV3, sqlx::Error> {
    if row.query_digest != expected.as_str()
        || row.verification_status != "VERIFIED"
        || row.public_use_status != "APPROVED"
    {
        return Err(domain_decode(
            RelationshipGraphError::UnapprovedRelationship,
        ));
    }
    let neighbor = RelationshipNeighborV3 {
        subject: endpoint_v3(row.subject)?,
        object: endpoint_v3(row.object)?,
        relationship_kind: relationship_kind(&row.relationship_kind)?,
        assertion_id: RelationshipGraphAssertionId::new(row.assertion_id).map_err(domain_decode)?,
        assertion_revision: positive_revision(row.assertion_revision)?,
        assertion_digest: digest(&row.assertion_digest)?,
        valid_from: row.valid_from,
        valid_to: row.valid_to,
        evidence_count: u16::try_from(row.evidence_count)
            .map_err(|_| domain_decode(RelationshipGraphError::UnapprovedRelationship))?,
        evidence_set_digest: digest(&row.evidence_set_digest)?,
        subject_source_use_id: RelationshipGraphSourceUseId::new(row.subject_source_use_id)
            .map_err(domain_decode)?,
        subject_source_use_sha256: digest(&row.subject_source_use_sha256)?,
        object_source_use_id: RelationshipGraphSourceUseId::new(row.object_source_use_id)
            .map_err(domain_decode)?,
        object_source_use_sha256: digest(&row.object_source_use_sha256)?,
        proposed_actor: actor(&row.proposed_actor_type, &row.proposed_actor_id)?,
        verified_by: RelationshipGraphUserId::new(row.verified_by).map_err(domain_decode)?,
        verified_at: row.verified_at,
        verification_reason_digest: digest(&row.verification_reason_digest)?,
    };
    neighbor.validate().map_err(domain_decode)?;
    Ok(neighbor)
}

fn endpoint_v3(value: Value) -> Result<RelationshipGraphEndpointV3, sqlx::Error> {
    let object = value
        .as_object()
        .ok_or_else(|| domain_decode(RelationshipGraphError::InvalidEndpoint))?;
    match string(object, "kind")? {
        "PERSON" if object.len() == 2 => Ok(RelationshipGraphEndpointV3::Person {
            person_node_ref: digest(string(object, "personNodeRef")?)?,
        }),
        "SUPPLIER" if object.len() == 2 => Ok(RelationshipGraphEndpointV3::Supplier {
            endpoint_id: endpoint_id(object)?,
        }),
        "AGENCY" if object.len() == 2 => Ok(RelationshipGraphEndpointV3::Agency {
            endpoint_id: endpoint_id(object)?,
        }),
        "PROCUREMENT_NOTICE" if object.len() == 2 => {
            Ok(RelationshipGraphEndpointV3::ProcurementNotice {
                endpoint_id: endpoint_id(object)?,
            })
        }
        "SANCTION" if object.len() == 2 => Ok(RelationshipGraphEndpointV3::Sanction {
            endpoint_id: endpoint_id(object)?,
        }),
        _ => Err(domain_decode(RelationshipGraphError::InvalidEndpoint)),
    }
}

fn endpoint_id(
    object: &serde_json::Map<String, Value>,
) -> Result<RelationshipGraphEndpointId, sqlx::Error> {
    RelationshipGraphEndpointId::new(uuid(object, "endpointId")?).map_err(domain_decode)
}

fn endpoint_kind(value: &str) -> Result<RelationshipEndpointKindV2, sqlx::Error> {
    match value {
        "SUPPLIER" => Ok(RelationshipEndpointKindV2::Supplier),
        "PERSON" => Ok(RelationshipEndpointKindV2::Person),
        "AGENCY" => Ok(RelationshipEndpointKindV2::Agency),
        "PROCUREMENT_NOTICE" => Ok(RelationshipEndpointKindV2::ProcurementNotice),
        "SANCTION" => Ok(RelationshipEndpointKindV2::Sanction),
        _ => Err(domain_decode(RelationshipGraphError::InvalidEndpoint)),
    }
}

fn relationship_kind(value: &str) -> Result<RelationshipKindV2, sqlx::Error> {
    match value {
        "OWNERSHIP" => Ok(RelationshipKindV2::Ownership),
        "BENEFICIAL_OWNERSHIP" => Ok(RelationshipKindV2::BeneficialOwnership),
        "CONTROL" => Ok(RelationshipKindV2::Control),
        "MANAGEMENT_ROLE" => Ok(RelationshipKindV2::ManagementRole),
        "LEGAL_REPRESENTATIVE" => Ok(RelationshipKindV2::LegalRepresentative),
        "CONTRACTUAL_RELATIONSHIP" => Ok(RelationshipKindV2::ContractualRelationship),
        "BID_PARTICIPATION" => Ok(RelationshipKindV2::BidParticipation),
        "SANCTION" => Ok(RelationshipKindV2::Sanction),
        "FORMER_OFFICIAL_ROLE" => Ok(RelationshipKindV2::FormerOfficialRole),
        _ => Err(domain_decode(
            RelationshipGraphError::ForbiddenRelationshipKind,
        )),
    }
}

fn verification_status(value: &str) -> Result<RelationshipVerificationStatusV2, sqlx::Error> {
    match value {
        "PENDING_HUMAN" => Ok(RelationshipVerificationStatusV2::PendingHuman),
        "VERIFIED" => Ok(RelationshipVerificationStatusV2::Verified),
        "REJECTED" => Ok(RelationshipVerificationStatusV2::Rejected),
        "CONFLICTED" => Ok(RelationshipVerificationStatusV2::Conflicted),
        "SUPERSEDED" => Ok(RelationshipVerificationStatusV2::Superseded),
        _ => Err(domain_decode(RelationshipGraphError::InvalidState)),
    }
}

fn public_status(value: &str) -> Result<RelationshipPublicUseStatusV2, sqlx::Error> {
    match value {
        "NOT_REVIEWED" => Ok(RelationshipPublicUseStatusV2::NotReviewed),
        "APPROVED" => Ok(RelationshipPublicUseStatusV2::Approved),
        "DENIED" => Ok(RelationshipPublicUseStatusV2::Denied),
        _ => Err(domain_decode(RelationshipGraphError::InvalidState)),
    }
}

fn identity_status(value: &str) -> Result<IdentityResolutionStatusV2, sqlx::Error> {
    match value {
        "PENDING_HUMAN" => Ok(IdentityResolutionStatusV2::PendingHuman),
        "NOT_APPLICABLE" => Ok(IdentityResolutionStatusV2::NotApplicable),
        _ => Err(domain_decode(RelationshipGraphError::InvalidState)),
    }
}

fn actor(kind: &str, id: &str) -> Result<RelationshipGraphActorV2, sqlx::Error> {
    match (kind, id) {
        ("SERVICE", "ingest-worker") => Ok(RelationshipGraphActorV2::ServiceIngestWorker),
        ("HUMAN", value) => Uuid::parse_str(value).map_err(json_decode).and_then(|id| {
            RelationshipGraphUserId::new(id)
                .map(RelationshipGraphActorV2::Human)
                .map_err(domain_decode)
        }),
        _ => Err(domain_decode(
            RelationshipGraphError::UnapprovedRelationship,
        )),
    }
}

fn exact_object<'a>(
    value: &'a Value,
    keys: &[&str],
) -> Result<&'a serde_json::Map<String, Value>, sqlx::Error> {
    let object = value
        .as_object()
        .ok_or_else(|| domain_decode(RelationshipGraphError::InvalidState))?;
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        Err(domain_decode(RelationshipGraphError::InvalidState))
    } else {
        Ok(object)
    }
}

fn string<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &str,
) -> Result<&'a str, sqlx::Error> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| domain_decode(RelationshipGraphError::InvalidState))
}

fn uuid(object: &serde_json::Map<String, Value>, key: &str) -> Result<Uuid, sqlx::Error> {
    Uuid::parse_str(string(object, key)?).map_err(json_decode)
}

fn boolean(object: &serde_json::Map<String, Value>, key: &str) -> Result<bool, sqlx::Error> {
    object
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| domain_decode(RelationshipGraphError::InvalidState))
}

fn positive_revision(value: i64) -> Result<u64, sqlx::Error> {
    u64::try_from(value)
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| domain_decode(RelationshipGraphError::InvalidState))
}

fn digest(value: &str) -> Result<Sha256Digest, sqlx::Error> {
    Sha256Digest::new(value.to_owned()).map_err(domain_decode)
}

pub(super) fn unexpected_null() -> sqlx::Error {
    sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))
}

pub(super) fn domain_decode(error: RelationshipGraphError) -> sqlx::Error {
    sqlx::Error::Decode(Box::new(error))
}

pub(super) fn json_decode(error: impl std::error::Error + Send + Sync + 'static) -> sqlx::Error {
    sqlx::Error::Decode(Box::new(error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn person_decoder_rejects_context_and_family_fields() {
        let value = json!({
            "kind":"PERSON", "personNodeRef":"a".repeat(64), "familyRelation":"부"
        });
        assert!(endpoint_v3(value).is_err());
    }
}
