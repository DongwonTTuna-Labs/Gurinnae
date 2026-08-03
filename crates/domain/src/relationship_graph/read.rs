use super::*;
use time::{Date, OffsetDateTime};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RelationshipGraphEndpointV3 {
    Supplier {
        #[serde(rename = "endpointId")]
        endpoint_id: RelationshipGraphEndpointId,
    },
    Person {
        #[serde(rename = "personNodeRef")]
        person_node_ref: Sha256Digest,
    },
    Agency {
        #[serde(rename = "endpointId")]
        endpoint_id: RelationshipGraphEndpointId,
    },
    ProcurementNotice {
        #[serde(rename = "endpointId")]
        endpoint_id: RelationshipGraphEndpointId,
    },
    Sanction {
        #[serde(rename = "endpointId")]
        endpoint_id: RelationshipGraphEndpointId,
    },
}

impl RelationshipGraphEndpointV3 {
    pub const fn kind(&self) -> RelationshipEndpointKindV2 {
        match self {
            Self::Supplier { .. } => RelationshipEndpointKindV2::Supplier,
            Self::Person { .. } => RelationshipEndpointKindV2::Person,
            Self::Agency { .. } => RelationshipEndpointKindV2::Agency,
            Self::ProcurementNotice { .. } => RelationshipEndpointKindV2::ProcurementNotice,
            Self::Sanction { .. } => RelationshipEndpointKindV2::Sanction,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ListRelationshipNeighborsV3 {
    pub agent_run_id: RelationshipGraphAgentRunId,
    pub snapshot_id: RelationshipGraphDatasetSnapshotId,
    pub snapshot_generation: u64,
    pub snapshot_sha256: Sha256Digest,
    pub selector: RelationshipGraphEndpointV3,
    pub relationship_kinds: Vec<RelationshipKindV2>,
    pub as_of: Option<Date>,
    pub limit: u8,
    /// Exact RFC 8785 bytes received at the closed provider boundary.
    pub request_canonical: Vec<u8>,
}

impl ListRelationshipNeighborsV3 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        if !positive_bigint(self.snapshot_generation)
            || !(1..=50).contains(&self.limit)
            || self.relationship_kinds.len() > 9
            || !self
                .relationship_kinds
                .windows(2)
                .all(|pair| pair[0] < pair[1])
            || self.request_canonical.is_empty()
        {
            Err(RelationshipGraphError::InvalidQuery)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipNeighborV3 {
    pub subject: RelationshipGraphEndpointV3,
    pub object: RelationshipGraphEndpointV3,
    pub relationship_kind: RelationshipKindV2,
    pub assertion_id: RelationshipGraphAssertionId,
    pub assertion_revision: u64,
    pub assertion_digest: Sha256Digest,
    pub valid_from: Option<Date>,
    pub valid_to: Option<Date>,
    pub evidence_count: u16,
    pub evidence_set_digest: Sha256Digest,
    pub subject_source_use_id: RelationshipGraphSourceUseId,
    pub subject_source_use_sha256: Sha256Digest,
    pub object_source_use_id: RelationshipGraphSourceUseId,
    pub object_source_use_sha256: Sha256Digest,
    pub proposed_actor: RelationshipGraphActorV2,
    pub verified_by: RelationshipGraphUserId,
    pub verified_at: OffsetDateTime,
    pub verification_reason_digest: Sha256Digest,
}

impl RelationshipNeighborV3 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        let same_human = matches!(
            &self.proposed_actor,
            RelationshipGraphActorV2::Human(id) if *id == self.verified_by
        );
        if self.assertion_revision == 0
            || !(1..=1000).contains(&self.evidence_count)
            || !valid_pair(
                self.relationship_kind,
                self.subject.kind(),
                self.object.kind(),
            )
            || self.subject == self.object
            || self
                .valid_from
                .zip(self.valid_to)
                .is_some_and(|pair| pair.0 > pair.1)
            || same_human
        {
            Err(RelationshipGraphError::UnapprovedRelationship)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipNeighborsV3 {
    pub query_digest: Sha256Digest,
    pub neighbors: Vec<RelationshipNeighborV3>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn person_provider_endpoint_contains_only_opaque_reference() {
        let endpoint = RelationshipGraphEndpointV3::Person {
            person_node_ref: Sha256Digest::new("a".repeat(64)).unwrap(),
        };
        let RelationshipGraphEndpointV3::Person { person_node_ref } = endpoint else {
            panic!("PERSON constructor must remain closed");
        };
        assert_eq!(person_node_ref.as_str(), "a".repeat(64));
    }

    #[test]
    fn query_requires_snapshot_fence_and_canonical_kind_order() {
        let query = ListRelationshipNeighborsV3 {
            agent_run_id: RelationshipGraphAgentRunId::new(Uuid::from_u128(1)).unwrap(),
            snapshot_id: RelationshipGraphDatasetSnapshotId::new(Uuid::from_u128(2)).unwrap(),
            snapshot_generation: 1,
            snapshot_sha256: Sha256Digest::new("b".repeat(64)).unwrap(),
            selector: RelationshipGraphEndpointV3::Supplier {
                endpoint_id: RelationshipGraphEndpointId::new(Uuid::from_u128(3)).unwrap(),
            },
            relationship_kinds: vec![RelationshipKindV2::Control, RelationshipKindV2::Ownership],
            as_of: None,
            limit: 10,
            request_canonical: vec![b'{', b'}'],
        };
        assert_eq!(query.validate(), Err(RelationshipGraphError::InvalidQuery));
    }
}
