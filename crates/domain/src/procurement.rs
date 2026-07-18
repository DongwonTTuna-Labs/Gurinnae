#![forbid(unsafe_code)]

//! Typed procurement facts and human-only identity/relationship decisions.
//!
//! The module deliberately keeps source values out of identity keys.  Provider
//! identifiers are represented by a lowercase SHA-256 HMAC and every change is
//! an immutable revision linked to its exact predecessor digest.

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RevisionIdentity {
    pub root_id: Uuid,
    pub revision_id: Uuid,
    pub revision: i64,
    pub record_digest: String,
    pub predecessor_revision_id: Option<Uuid>,
    pub predecessor_record_digest: Option<String>,
}

impl RevisionIdentity {
    pub fn validate(&self) -> Result<(), ProcurementError> {
        if self.revision < 1 || !is_digest(&self.record_digest) {
            return Err(ProcurementError::InvalidDigest);
        }
        if self.revision == 1 {
            if self.root_id != self.revision_id
                || self.predecessor_revision_id.is_some()
                || self.predecessor_record_digest.is_some()
            {
                return Err(ProcurementError::InvalidPredecessor);
            }
        } else if self.root_id == self.revision_id
            || self.predecessor_revision_id.is_none()
            || !self
                .predecessor_record_digest
                .as_deref()
                .is_some_and(is_digest)
        {
            return Err(ProcurementError::InvalidPredecessor);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SourceLocator {
    pub source_document_id: Uuid,
    pub source_asset_id: Uuid,
    pub source_asset_revision: i64,
    pub source_content_sha256: String,
    pub locator_digest: String,
}

impl SourceLocator {
    pub fn validate(&self) -> Result<(), ProcurementError> {
        if self.source_asset_revision < 1
            || !is_digest(&self.source_content_sha256)
            || !is_digest(&self.locator_digest)
        {
            return Err(ProcurementError::InvalidDigest);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProcurementNoticeRevision {
    pub identity: RevisionIdentity,
    pub source: SourceLocator,
    pub record_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AwardRevision {
    pub identity: RevisionIdentity,
    pub source: SourceLocator,
    pub notice_revision_id: Uuid,
    pub record_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AwardWinnerRevision {
    pub award_revision_id: Uuid,
    pub winner_ordinal: i32,
    pub member_digest: String,
    pub candidate_id: Uuid,
    pub candidate_revision: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BidderParticipationRevision {
    pub identity: RevisionIdentity,
    pub source: SourceLocator,
    pub record_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProcurementContractRevision {
    pub identity: RevisionIdentity,
    pub source: SourceLocator,
    pub agency_id: Uuid,
    pub record_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContractSupplierRevision {
    pub contract_revision_id: Uuid,
    pub supplier_ordinal: i32,
    pub supplier_digest: String,
    pub candidate_id: Uuid,
    pub candidate_revision: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContractAmendmentRevision {
    pub identity: RevisionIdentity,
    pub source: SourceLocator,
    pub contract_before_revision_id: Uuid,
    pub contract_after_revision_id: Uuid,
    pub record_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProcurementContractLineItemRevision {
    pub line_item_id: Uuid,
    pub line_item_revision: i64,
    pub line_item_digest: String,
    pub contract_revision_id: Uuid,
    pub source: SourceLocator,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProcurementContractLineItemComponent {
    pub line_item_id: Uuid,
    pub line_item_revision: i64,
    pub component_ordinal: i32,
    pub component_digest: String,
    pub source: SourceLocator,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SupplierIdentityCandidate {
    pub candidate_id: Uuid,
    pub candidate_revision: i64,
    pub candidate_digest: String,
    pub predecessor_candidate_digest: Option<String>,
    pub normalized_name: String,
    pub identifier_hmacs: Vec<String>,
    pub source: SourceLocator,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SupplierIdentityResolutionDecision {
    pub decision_id: Uuid,
    pub decision_sequence: i64,
    pub action: IdentityResolutionAction,
    pub candidate_ids: Vec<Uuid>,
    pub from_canonical_supplier_ids: Vec<Uuid>,
    pub to_canonical_supplier_ids: Vec<Uuid>,
    pub evidence_locators: Vec<SourceLocator>,
    pub expected_candidate_set_digest: String,
    pub prior_decision_digest: Option<String>,
    pub decision_digest: String,
    pub actor_user_id: Uuid,
    pub decided_at: OffsetDateTime,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SupplierIdentityResolutionDecisionMember {
    pub decision_id: Uuid,
    pub member_ordinal: i32,
    pub candidate_id: Uuid,
    pub candidate_revision: i64,
    pub candidate_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SupplierRelationshipAssertion {
    pub assertion_id: Uuid,
    pub assertion_revision: i64,
    pub assertion_digest: String,
    pub predecessor_assertion_digest: Option<String>,
    pub relationship_kind: RelationshipKind,
    pub subject_identity_key_digest: String,
    pub object_identity_key_digest: String,
    pub verification_status: RelationshipVerificationStatus,
    pub evidence_locator_set_digest: String,
    pub verified_by: Option<Uuid>,
    pub verified_at: Option<OffsetDateTime>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SupplierRelationshipAssertionEvidence {
    pub assertion_id: Uuid,
    pub assertion_revision: i64,
    pub evidence_ordinal: i32,
    pub evidence_digest: String,
    pub locator: SourceLocator,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProcurementQuerySnapshot {
    pub snapshot_id: Uuid,
    pub filter_digest: String,
    pub member_set_digest: String,
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProcurementQuerySnapshotMember {
    pub snapshot_id: Uuid,
    pub member_ordinal: i32,
    pub member_digest: String,
    pub contract_revision_id: Uuid,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum IdentityResolutionAction {
    Merge,
    Split,
    KeepSeparate,
    MarkAmbiguous,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum RelationshipKind {
    Ownership,
    BeneficialOwnership,
    Control,
    ManagementRole,
    LegalRepresentative,
    ContractualRelationship,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum RelationshipVerificationStatus {
    Pending,
    Verified,
    Rejected,
    Conflicted,
    Superseded,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum ProcurementError {
    #[error("invalid SHA-256 digest")]
    InvalidDigest,
    #[error("invalid immutable predecessor")]
    InvalidPredecessor,
    #[error("automatic supplier merge is forbidden")]
    AutomaticMergeForbidden,
    #[error("relationship assertion must be decided by an independent actor")]
    NonIndependentDecision,
    #[error("stale revision or evidence digest")]
    StaleRevision,
}

pub fn validate_hmac_identifier(value: &str) -> Result<(), ProcurementError> {
    if is_digest(value) {
        Ok(())
    } else {
        Err(ProcurementError::InvalidDigest)
    }
}

fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}
