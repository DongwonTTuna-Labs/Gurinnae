use super::SnapshotBinding;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Closed selector for the typed relationship graph. Natural-person pivots use
/// a run-and-snapshot-scoped opaque reference; the hidden endpoint identity,
/// identifier fact digest, and L4 context stay inside the trusted database
/// boundary.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "SCREAMING_SNAKE_CASE", deny_unknown_fields)]
pub enum RelationshipEndpointSelectorV3 {
    Supplier {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
    Person {
        #[serde(rename = "personNodeRef")]
        person_node_ref: String,
    },
    Agency {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
    ProcurementNotice {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
    Sanction {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
}

impl RelationshipEndpointSelectorV3 {
    pub fn is_valid(&self) -> bool {
        match self {
            Self::Supplier { endpoint_id }
            | Self::Agency { endpoint_id }
            | Self::ProcurementNotice { endpoint_id }
            | Self::Sanction { endpoint_id } => !endpoint_id.is_nil(),
            Self::Person { person_node_ref } => is_lower_sha256(person_node_ref),
        }
    }

    pub const fn kind(&self) -> RelationshipEndpointKindV3 {
        match self {
            Self::Supplier { .. } => RelationshipEndpointKindV3::Supplier,
            Self::Person { .. } => RelationshipEndpointKindV3::Person,
            Self::Agency { .. } => RelationshipEndpointKindV3::Agency,
            Self::ProcurementNotice { .. } => RelationshipEndpointKindV3::ProcurementNotice,
            Self::Sanction { .. } => RelationshipEndpointKindV3::Sanction,
        }
    }
}

pub(super) fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RelationshipEndpointKindV3 {
    Supplier,
    Person,
    Agency,
    ProcurementNotice,
    Sanction,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RelationshipKindV3 {
    Ownership,
    BeneficialOwnership,
    Control,
    ManagementRole,
    LegalRepresentative,
    ContractualRelationship,
    BidParticipation,
    Sanction,
    FormerOfficialRole,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RelationshipNeighborsRequestV3 {
    pub binding: SnapshotBinding,
    pub selector: RelationshipEndpointSelectorV3,
    pub relationship_kinds: Vec<RelationshipKindV3>,
    pub as_of: Option<String>,
    pub limit: u8,
}

/// Provider-visible endpoint. PERSON deliberately exposes only a
/// run-and-snapshot-scoped opaque reference. Contextual name, title, source
/// locator, hidden endpoint identity, and identifier-fact digest remain
/// available to trusted reviewer paths but must never enter a relay payload.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "SCREAMING_SNAKE_CASE", deny_unknown_fields)]
pub enum RelationshipEndpointV3 {
    Supplier {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
    Person {
        #[serde(rename = "personNodeRef")]
        person_node_ref: String,
    },
    Agency {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
    ProcurementNotice {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
    Sanction {
        #[serde(rename = "endpointId")]
        endpoint_id: Uuid,
    },
}

impl RelationshipEndpointV3 {
    pub const fn kind(&self) -> RelationshipEndpointKindV3 {
        match self {
            Self::Supplier { .. } => RelationshipEndpointKindV3::Supplier,
            Self::Person { .. } => RelationshipEndpointKindV3::Person,
            Self::Agency { .. } => RelationshipEndpointKindV3::Agency,
            Self::ProcurementNotice { .. } => RelationshipEndpointKindV3::ProcurementNotice,
            Self::Sanction { .. } => RelationshipEndpointKindV3::Sanction,
        }
    }

    pub fn stable_key(&self) -> String {
        match self {
            Self::Supplier { endpoint_id }
            | Self::Agency { endpoint_id }
            | Self::ProcurementNotice { endpoint_id }
            | Self::Sanction { endpoint_id } => endpoint_id.to_string(),
            Self::Person { person_node_ref } => person_node_ref.clone(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelationshipNeighborV3 {
    pub subject: RelationshipEndpointV3,
    pub object: RelationshipEndpointV3,
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

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelationshipNeighborsResponseV3 {
    pub schema_version: String,
    pub query_digest: String,
    pub neighbors: Vec<RelationshipNeighborV3>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn person_wire_shape_is_opaque_and_closed() {
        let endpoint = RelationshipEndpointV3::Person {
            person_node_ref: "a".repeat(64),
        };
        let Some(value) = serde_json::to_value(endpoint).ok() else {
            panic!("closed endpoint must serialize");
        };
        assert_eq!(value["kind"], "PERSON");
        assert_eq!(value["personNodeRef"], "a".repeat(64));
        for forbidden in [
            "contextualName",
            "roleTitle",
            "sourceLocator",
            "identifierDigest",
            "familyRelationship",
            "score",
            "rank",
            "probability",
        ] {
            assert!(
                value.get(forbidden).is_none(),
                "forbidden wire field {forbidden}"
            );
        }
    }

    #[test]
    fn selector_rejects_nil_and_non_digest_person_keys() {
        assert!(
            !RelationshipEndpointSelectorV3::Supplier {
                endpoint_id: Uuid::nil()
            }
            .is_valid()
        );
        assert!(
            !RelationshipEndpointSelectorV3::Person {
                person_node_ref: "person-name".to_owned()
            }
            .is_valid()
        );
        assert!(
            RelationshipEndpointSelectorV3::Person {
                person_node_ref: "f".repeat(64)
            }
            .is_valid()
        );
        assert!(
            !RelationshipEndpointSelectorV3::Person {
                person_node_ref: "F".repeat(64)
            }
            .is_valid()
        );
    }

    #[test]
    fn person_wire_rejects_stable_digest_and_l4_context_fields() {
        let old_digest = serde_json::json!({
            "kind": "PERSON",
            "personNodeDigest": "a".repeat(64),
        });
        let leaked_context = serde_json::json!({
            "kind": "PERSON",
            "personNodeRef": "b".repeat(64),
            "contextualName": "외부 전송 금지",
        });
        assert!(serde_json::from_value::<RelationshipEndpointV3>(old_digest).is_err());
        assert!(serde_json::from_value::<RelationshipEndpointV3>(leaked_context).is_err());
    }

    #[test]
    fn endpoint_and_relationship_kind_catalogs_are_closed() {
        let endpoint_kinds = [
            RelationshipEndpointKindV3::Supplier,
            RelationshipEndpointKindV3::Person,
            RelationshipEndpointKindV3::Agency,
            RelationshipEndpointKindV3::ProcurementNotice,
            RelationshipEndpointKindV3::Sanction,
        ];
        let relationship_kinds = [
            RelationshipKindV3::Ownership,
            RelationshipKindV3::BeneficialOwnership,
            RelationshipKindV3::Control,
            RelationshipKindV3::ManagementRole,
            RelationshipKindV3::LegalRepresentative,
            RelationshipKindV3::ContractualRelationship,
            RelationshipKindV3::BidParticipation,
            RelationshipKindV3::Sanction,
            RelationshipKindV3::FormerOfficialRole,
        ];
        assert_eq!(endpoint_kinds.len(), 5);
        assert_eq!(relationship_kinds.len(), 9);
        assert!(
            serde_json::from_value::<RelationshipKindV3>(serde_json::json!("FAMILY_RELATIONSHIP"))
                .is_err()
        );
    }
}
