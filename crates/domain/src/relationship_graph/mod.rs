#![forbid(unsafe_code)]

//! Closed domain boundary for the R6c typed relationship graph.
//!
//! Family or kinship edges are deliberately unrepresentable. Natural-person
//! endpoints accept only the L4 public-source context, while v3 reads expose a
//! run-and-snapshot-scoped opaque reference instead of that context.

mod assertion;
mod endpoint;
mod read;

pub use assertion::*;
pub use endpoint::*;
pub use read::*;

use serde::Serialize;
use uuid::Uuid;

macro_rules! typed_uuid {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            pub fn new(value: Uuid) -> Result<Self, RelationshipGraphError> {
                (!value.is_nil())
                    .then_some(Self(value))
                    .ok_or(RelationshipGraphError::InvalidIdentifier)
            }

            pub const fn value(self) -> Uuid {
                self.0
            }
        }
    };
}

typed_uuid!(RelationshipGraphEndpointId);
typed_uuid!(RelationshipGraphAssertionId);
typed_uuid!(RelationshipGraphDecisionId);
typed_uuid!(RelationshipGraphEntityId);
typed_uuid!(RelationshipGraphSourceDocumentId);
typed_uuid!(RelationshipGraphSourceAssetId);
typed_uuid!(RelationshipGraphParserRunId);
typed_uuid!(RelationshipGraphParsedRecordId);
typed_uuid!(RelationshipGraphEvidenceId);
typed_uuid!(RelationshipGraphAgentRunId);
typed_uuid!(RelationshipGraphSourceUseId);
typed_uuid!(RelationshipGraphUserId);
typed_uuid!(RelationshipGraphDatasetSnapshotId);

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct Sha256Digest(String);

impl Sha256Digest {
    pub fn new(value: impl Into<String>) -> Result<Self, RelationshipGraphError> {
        let value = value.into();
        if value.len() == 64
            && value
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        {
            Ok(Self(value))
        } else {
            Err(RelationshipGraphError::InvalidDigest)
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RelationshipEndpointKindV2 {
    Supplier,
    Person,
    Agency,
    ProcurementNotice,
    Sanction,
}

impl RelationshipEndpointKindV2 {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Supplier => "SUPPLIER",
            Self::Person => "PERSON",
            Self::Agency => "AGENCY",
            Self::ProcurementNotice => "PROCUREMENT_NOTICE",
            Self::Sanction => "SANCTION",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RelationshipKindV2 {
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

impl RelationshipKindV2 {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ownership => "OWNERSHIP",
            Self::BeneficialOwnership => "BENEFICIAL_OWNERSHIP",
            Self::Control => "CONTROL",
            Self::ManagementRole => "MANAGEMENT_ROLE",
            Self::LegalRepresentative => "LEGAL_REPRESENTATIVE",
            Self::ContractualRelationship => "CONTRACTUAL_RELATIONSHIP",
            Self::BidParticipation => "BID_PARTICIPATION",
            Self::Sanction => "SANCTION",
            Self::FormerOfficialRole => "FORMER_OFFICIAL_ROLE",
        }
    }
}

pub(super) fn bounded(value: &str, maximum: usize) -> Result<(), RelationshipGraphError> {
    if value.trim().is_empty() {
        Err(RelationshipGraphError::EmptyValue)
    } else if value.chars().count() > maximum {
        Err(RelationshipGraphError::ValueTooLong)
    } else {
        Ok(())
    }
}

pub(super) fn positive_bigint(value: u64) -> bool {
    value > 0 && i64::try_from(value).is_ok()
}

pub(super) fn valid_pair(
    kind: RelationshipKindV2,
    subject: RelationshipEndpointKindV2,
    object: RelationshipEndpointKindV2,
) -> bool {
    matches!(
        (kind, subject, object),
        (
            RelationshipKindV2::Ownership
                | RelationshipKindV2::BeneficialOwnership
                | RelationshipKindV2::Control
                | RelationshipKindV2::ContractualRelationship,
            RelationshipEndpointKindV2::Supplier,
            RelationshipEndpointKindV2::Supplier
        ) | (
            RelationshipKindV2::ManagementRole | RelationshipKindV2::LegalRepresentative,
            RelationshipEndpointKindV2::Person,
            RelationshipEndpointKindV2::Supplier
        ) | (
            RelationshipKindV2::BidParticipation,
            RelationshipEndpointKindV2::Supplier,
            RelationshipEndpointKindV2::ProcurementNotice
        ) | (
            RelationshipKindV2::Sanction,
            RelationshipEndpointKindV2::Supplier,
            RelationshipEndpointKindV2::Sanction
        ) | (
            RelationshipKindV2::FormerOfficialRole,
            RelationshipEndpointKindV2::Person,
            RelationshipEndpointKindV2::Agency
        )
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum RelationshipGraphError {
    #[error("required graph value is empty")]
    EmptyValue,
    #[error("graph value exceeds its closed length limit")]
    ValueTooLong,
    #[error("graph UUID must be non-nil")]
    InvalidIdentifier,
    #[error("graph digest must be lowercase SHA-256")]
    InvalidDigest,
    #[error("typed endpoint is invalid")]
    InvalidEndpoint,
    #[error("PERSON endpoint violates the L4 minimal-source boundary")]
    PersonL4Boundary,
    #[error("family, kinship, or unknown relationship kinds are forbidden")]
    ForbiddenRelationshipKind,
    #[error("relationship kind does not admit this endpoint pair")]
    InvalidRelationshipPair,
    #[error("source lineage is invalid")]
    InvalidSource,
    #[error("evidence binding is invalid")]
    InvalidEvidence,
    #[error("relationship validity window is invalid")]
    InvalidValidity,
    #[error("relationship state is invalid")]
    InvalidState,
    #[error("relationship decision is invalid")]
    InvalidDecision,
    #[error("relationship query is invalid")]
    InvalidQuery,
    #[error("relationship is not independently VERIFIED and APPROVED")]
    UnapprovedRelationship,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_has_no_family_or_kinship_kind() {
        let names = [
            RelationshipKindV2::Ownership.as_str(),
            RelationshipKindV2::BeneficialOwnership.as_str(),
            RelationshipKindV2::Control.as_str(),
            RelationshipKindV2::ManagementRole.as_str(),
            RelationshipKindV2::LegalRepresentative.as_str(),
            RelationshipKindV2::ContractualRelationship.as_str(),
            RelationshipKindV2::BidParticipation.as_str(),
            RelationshipKindV2::Sanction.as_str(),
            RelationshipKindV2::FormerOfficialRole.as_str(),
        ];
        assert_eq!(names.len(), 9);
        assert!(
            names
                .iter()
                .all(|name| !name.contains("FAMILY") && !name.contains("KINSHIP"))
        );
    }

    #[test]
    fn typed_ids_and_digests_fail_closed() {
        assert_eq!(
            RelationshipGraphEndpointId::new(Uuid::nil()),
            Err(RelationshipGraphError::InvalidIdentifier)
        );
        assert_eq!(
            Sha256Digest::new("A".repeat(64)),
            Err(RelationshipGraphError::InvalidDigest)
        );
    }
}
