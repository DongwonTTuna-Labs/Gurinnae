use super::*;
use time::Date;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelationshipEvidenceSourceV2 {
    SourceDocument {
        document_id: RelationshipGraphSourceDocumentId,
        asset_id: RelationshipGraphSourceAssetId,
        asset_revision: u64,
        content_sha256: Sha256Digest,
    },
    SourceUse {
        agent_run_id: RelationshipGraphAgentRunId,
        source_use_id: RelationshipGraphSourceUseId,
        source_use_sha256: Sha256Digest,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipGraphAssertionEvidenceV2 {
    pub evidence_id: RelationshipGraphEvidenceId,
    pub evidence_version: u64,
    pub evidence_digest: Sha256Digest,
    pub source: RelationshipEvidenceSourceV2,
    pub locator_digest: Sha256Digest,
}

impl RelationshipGraphAssertionEvidenceV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        let source_valid = match &self.source {
            RelationshipEvidenceSourceV2::SourceDocument { asset_revision, .. } => {
                positive_bigint(*asset_revision)
            }
            RelationshipEvidenceSourceV2::SourceUse { .. } => true,
        };
        (positive_bigint(self.evidence_version) && source_valid)
            .then_some(())
            .ok_or(RelationshipGraphError::InvalidEvidence)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ValidityCoverageStatusV2 {
    Complete,
    Partial,
    Unknown,
    NotAvailable,
}

impl ValidityCoverageStatusV2 {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Complete => "COMPLETE",
            Self::Partial => "PARTIAL",
            Self::Unknown => "UNKNOWN",
            Self::NotAvailable => "NOT_AVAILABLE",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelationshipGraphActorV2 {
    ServiceIngestWorker,
    Human(RelationshipGraphUserId),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordRelationshipGraphAssertionV2 {
    pub assertion_id: RelationshipGraphAssertionId,
    pub relationship_kind: RelationshipKindV2,
    pub source_kind: String,
    pub source_locator: String,
    pub subject: RelationshipGraphEndpointRefV2,
    pub object: RelationshipGraphEndpointRefV2,
    pub valid_from: Option<Date>,
    pub valid_to: Option<Date>,
    pub departed_on: Option<Date>,
    pub coverage: ValidityCoverageStatusV2,
    pub evidence: Vec<RelationshipGraphAssertionEvidenceV2>,
    pub proposed_actor: RelationshipGraphActorV2,
}

impl RecordRelationshipGraphAssertionV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        bounded(&self.source_kind, 128)?;
        bounded(&self.source_locator, 2048)?;
        if self.subject.endpoint_id == self.object.endpoint_id
            || !valid_pair(
                self.relationship_kind,
                self.subject.endpoint_kind,
                self.object.endpoint_kind,
            )
        {
            return Err(RelationshipGraphError::InvalidRelationshipPair);
        }
        if self
            .valid_from
            .zip(self.valid_to)
            .is_some_and(|pair| pair.0 > pair.1)
        {
            return Err(RelationshipGraphError::InvalidValidity);
        }
        if self.evidence.is_empty()
            || self.evidence.len() > 1000
            || self.evidence.iter().any(|item| item.validate().is_err())
        {
            return Err(RelationshipGraphError::InvalidEvidence);
        }
        if self.relationship_kind == RelationshipKindV2::FormerOfficialRole {
            if self.departed_on.is_none()
                || self.departed_on != self.valid_to
                || !matches!(
                    self.source_kind.as_str(),
                    "PUBLIC_OFFICIAL_ETHICS_NOTICE" | "OFFICIAL_GAZETTE"
                )
            {
                return Err(RelationshipGraphError::InvalidValidity);
            }
        } else if self.departed_on.is_some() {
            return Err(RelationshipGraphError::InvalidValidity);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RelationshipVerificationStatusV2 {
    PendingHuman,
    Verified,
    Rejected,
    Conflicted,
    Superseded,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RelationshipPublicUseStatusV2 {
    NotReviewed,
    Approved,
    Denied,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipGraphAssertionV2 {
    pub assertion_id: RelationshipGraphAssertionId,
    pub assertion_revision: u64,
    pub assertion_digest: Sha256Digest,
    pub receipt_sha256: Sha256Digest,
    pub verification_status: RelationshipVerificationStatusV2,
    pub public_use_status: RelationshipPublicUseStatusV2,
    pub replayed: bool,
}

impl RelationshipGraphAssertionV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        let pair = (self.verification_status, self.public_use_status);
        if self.assertion_revision == 0
            || !matches!(
                pair,
                (
                    RelationshipVerificationStatusV2::PendingHuman,
                    RelationshipPublicUseStatusV2::NotReviewed
                ) | (
                    RelationshipVerificationStatusV2::Verified,
                    RelationshipPublicUseStatusV2::Approved
                ) | (
                    RelationshipVerificationStatusV2::Rejected
                        | RelationshipVerificationStatusV2::Conflicted
                        | RelationshipVerificationStatusV2::Superseded,
                    RelationshipPublicUseStatusV2::Denied
                )
            )
        {
            Err(RelationshipGraphError::InvalidState)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RelationshipDecisionKindV2 {
    Verify,
    Reject,
    MarkConflict,
    Supersede,
}

impl RelationshipDecisionKindV2 {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Verify => "VERIFY",
            Self::Reject => "REJECT",
            Self::MarkConflict => "MARK_CONFLICT",
            Self::Supersede => "SUPERSEDE",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DecideRelationshipGraphAssertionV2 {
    pub assertion_id: RelationshipGraphAssertionId,
    pub decision: RelationshipDecisionKindV2,
    pub reason_code: String,
    pub reason: String,
    pub actor_user_id: RelationshipGraphUserId,
}

impl DecideRelationshipGraphAssertionV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        bounded(&self.reason_code, 100)?;
        if self.reason.trim().is_empty() || self.reason.len() > 2000 {
            Err(RelationshipGraphError::InvalidDecision)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipGraphVerificationDecisionV2 {
    pub decision_id: RelationshipGraphDecisionId,
    pub assertion: RelationshipGraphAssertionV2,
}

impl RelationshipGraphVerificationDecisionV2 {
    pub fn validate(&self) -> Result<(), RelationshipGraphError> {
        self.assertion.validate()?;
        if self.assertion.assertion_revision < 2
            || self.assertion.verification_status == RelationshipVerificationStatusV2::PendingHuman
        {
            Err(RelationshipGraphError::InvalidState)
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pair_catalog_rejects_person_bid_participation() {
        assert!(valid_pair(
            RelationshipKindV2::BidParticipation,
            RelationshipEndpointKindV2::Supplier,
            RelationshipEndpointKindV2::ProcurementNotice
        ));
        assert!(!valid_pair(
            RelationshipKindV2::BidParticipation,
            RelationshipEndpointKindV2::Person,
            RelationshipEndpointKindV2::ProcurementNotice
        ));
    }

    #[test]
    fn only_verified_rows_can_be_approved() {
        let assertion = RelationshipGraphAssertionV2 {
            assertion_id: RelationshipGraphAssertionId::new(Uuid::from_u128(1)).unwrap(),
            assertion_revision: 2,
            assertion_digest: Sha256Digest::new("a".repeat(64)).unwrap(),
            receipt_sha256: Sha256Digest::new("b".repeat(64)).unwrap(),
            verification_status: RelationshipVerificationStatusV2::Rejected,
            public_use_status: RelationshipPublicUseStatusV2::Approved,
            replayed: false,
        };
        assert_eq!(
            assertion.validate(),
            Err(RelationshipGraphError::InvalidState)
        );
    }
}
