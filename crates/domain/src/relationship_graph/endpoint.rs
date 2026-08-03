use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ParsedRelationshipSourceV2 {
    pub document_id: RelationshipGraphSourceDocumentId,
    pub asset_id: RelationshipGraphSourceAssetId,
    pub asset_revision: u64,
    pub content_sha256: Sha256Digest,
    pub parser_run_id: RelationshipGraphParserRunId,
    pub parsed_record_id: RelationshipGraphParsedRecordId,
    pub parser_version: String,
    pub parsed_payload_sha256: Sha256Digest,
}

impl ParsedRelationshipSourceV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        if !positive_bigint(self.asset_revision) || self.parser_version.trim().is_empty() {
            Err(RelationshipGraphError::InvalidSource)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelationshipEndpointIdentityV2 {
    Person {
        contextual_name: String,
        role_title: String,
    },
    Entity {
        entity_id: RelationshipGraphEntityId,
        entity_revision: u64,
        entity_digest: Sha256Digest,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordRelationshipGraphEndpointV2 {
    pub kind: RelationshipEndpointKindV2,
    pub identity: RelationshipEndpointIdentityV2,
    pub source_kind: String,
    pub source_locator: String,
    pub identifier_digest: Sha256Digest,
    pub source: ParsedRelationshipSourceV2,
}

impl RecordRelationshipGraphEndpointV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        self.source.validate()?;
        bounded(&self.source_kind, 100)?;
        bounded(&self.source_locator, 2048)?;
        match (&self.kind, &self.identity) {
            (
                RelationshipEndpointKindV2::Person,
                RelationshipEndpointIdentityV2::Person {
                    contextual_name,
                    role_title,
                },
            ) => {
                bounded(contextual_name, 300)?;
                bounded(role_title, 300)?;
                if !is_person_source(&self.source_kind) {
                    return Err(RelationshipGraphError::PersonL4Boundary);
                }
            }
            (RelationshipEndpointKindV2::Person, _)
            | (_, RelationshipEndpointIdentityV2::Person { .. }) => {
                return Err(RelationshipGraphError::PersonL4Boundary);
            }
            (
                _,
                RelationshipEndpointIdentityV2::Entity {
                    entity_revision, ..
                },
            ) if positive_bigint(*entity_revision) => {}
            _ => return Err(RelationshipGraphError::InvalidEndpoint),
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IdentityResolutionStatusV2 {
    PendingHuman,
    NotApplicable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipGraphEndpointV2 {
    pub endpoint_id: RelationshipGraphEndpointId,
    pub endpoint_kind: RelationshipEndpointKindV2,
    pub endpoint_digest: Sha256Digest,
    pub identity_resolution_status: IdentityResolutionStatusV2,
    pub replayed: bool,
}

impl RelationshipGraphEndpointV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        let valid = match self.endpoint_kind {
            RelationshipEndpointKindV2::Person => {
                self.identity_resolution_status == IdentityResolutionStatusV2::PendingHuman
            }
            _ => self.identity_resolution_status == IdentityResolutionStatusV2::NotApplicable,
        };
        valid
            .then_some(())
            .ok_or(RelationshipGraphError::InvalidState)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipGraphEndpointRefV2 {
    pub endpoint_id: RelationshipGraphEndpointId,
    pub endpoint_kind: RelationshipEndpointKindV2,
    pub endpoint_digest: Sha256Digest,
}

fn is_person_source(value: &str) -> bool {
    matches!(
        value,
        "DART_EXECUTIVE_STATUS"
            | "ALIO_EXECUTIVE_STATUS"
            | "OFFICIAL_GAZETTE"
            | "PUBLIC_OFFICIAL_ETHICS_NOTICE"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source() -> ParsedRelationshipSourceV2 {
        ParsedRelationshipSourceV2 {
            document_id: RelationshipGraphSourceDocumentId::new(Uuid::from_u128(1)).unwrap(),
            asset_id: RelationshipGraphSourceAssetId::new(Uuid::from_u128(2)).unwrap(),
            asset_revision: 1,
            content_sha256: Sha256Digest::new("a".repeat(64)).unwrap(),
            parser_run_id: RelationshipGraphParserRunId::new(Uuid::from_u128(3)).unwrap(),
            parsed_record_id: RelationshipGraphParsedRecordId::new(Uuid::from_u128(4)).unwrap(),
            parser_version: "r6c-v1".to_owned(),
            parsed_payload_sha256: Sha256Digest::new("b".repeat(64)).unwrap(),
        }
    }

    #[test]
    fn person_requires_l4_source_and_has_no_entity_identity() {
        let command = RecordRelationshipGraphEndpointV2 {
            kind: RelationshipEndpointKindV2::Person,
            identity: RelationshipEndpointIdentityV2::Person {
                contextual_name: "공시 맥락 성명".to_owned(),
                role_title: "대표이사".to_owned(),
            },
            source_kind: "UNVERIFIED_DIRECTORY".to_owned(),
            source_locator: "document:1#officer".to_owned(),
            identifier_digest: Sha256Digest::new("c".repeat(64)).unwrap(),
            source: source(),
        };
        assert_eq!(
            command.validate(),
            Err(RelationshipGraphError::PersonL4Boundary)
        );
    }
}
