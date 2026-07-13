use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::{
    claim::Claim,
    error::{DomainError, validated_text},
    ids::{CaseId, ClaimId, PublicationId, UserId},
    state_catalog::{ClaimValidationStatus, PublicationState},
};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum PublicationChangeKind {
    Initial,
    Correction,
    Retraction,
    AccessRestriction,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct HumanApproval {
    pub approved_by: UserId,
    pub role: String,
    pub snapshot_sha256: String,
    pub approved_at: OffsetDateTime,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PublicationRevision {
    pub publication_id: PublicationId,
    pub case_id: CaseId,
    pub revision: i64,
    pub state: PublicationState,
    pub change_kind: PublicationChangeKind,
    pub claim_ids: Vec<ClaimId>,
    pub reason: String,
    pub editor_approval: HumanApproval,
    pub legal_approval: Option<HumanApproval>,
    pub created_at: OffsetDateTime,
}

pub struct NewPublicationRevision<'a> {
    pub publication_id: PublicationId,
    pub case_id: CaseId,
    pub previous_revision: Option<&'a PublicationRevision>,
    pub state: PublicationState,
    pub change_kind: PublicationChangeKind,
    pub claims: &'a [Claim],
    pub reason: String,
    pub editor_approval: HumanApproval,
    pub legal_approval: Option<HumanApproval>,
    pub created_at: OffsetDateTime,
}

impl PublicationRevision {
    pub fn create(command: NewPublicationRevision<'_>) -> Result<Self, DomainError> {
        if command.claims.is_empty()
            || command
                .claims
                .iter()
                .any(|claim| claim.status != ClaimValidationStatus::Valid)
            || command
                .legal_approval
                .as_ref()
                .is_some_and(|approval| approval.approved_by == command.editor_approval.approved_by)
        {
            return Err(DomainError::HumanApprovalRequired);
        }
        if matches!(
            command.change_kind,
            PublicationChangeKind::Correction | PublicationChangeKind::Retraction
        ) != command.previous_revision.is_some()
        {
            return Err(DomainError::InvalidTransition);
        }
        let revision = command
            .previous_revision
            .map_or(1, |previous| previous.revision + 1);
        Ok(Self {
            publication_id: command.publication_id,
            case_id: command.case_id,
            revision,
            state: command.state,
            change_kind: command.change_kind,
            claim_ids: command.claims.iter().map(|claim| claim.id).collect(),
            reason: validated_text(command.reason, 4_000)?,
            editor_approval: command.editor_approval,
            legal_approval: command.legal_approval,
            created_at: command.created_at,
        })
    }
}
