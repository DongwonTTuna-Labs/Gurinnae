use serde::{Deserialize, Serialize};

use crate::{
    error::{DomainError, validated_text},
    evidence::Evidence,
    ids::{CaseId, ClaimId, EvidenceId, UserId},
    state_catalog::ClaimValidationStatus,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Claim {
    pub id: ClaimId,
    pub case_id: CaseId,
    pub text: String,
    pub evidence_ids: Vec<EvidenceId>,
    pub status: ClaimValidationStatus,
    pub authored_by: UserId,
    pub validated_by: Option<UserId>,
    pub version: i64,
}

impl Claim {
    pub fn draft(
        id: ClaimId,
        case_id: CaseId,
        text: impl Into<String>,
        evidence_ids: Vec<EvidenceId>,
        authored_by: UserId,
    ) -> Result<Self, DomainError> {
        if evidence_ids.is_empty() {
            return Err(DomainError::EvidenceNotPublishable);
        }
        Ok(Self {
            id,
            case_id,
            text: validated_text(text, 4_000)?,
            evidence_ids,
            status: ClaimValidationStatus::Draft,
            authored_by,
            validated_by: None,
            version: 1,
        })
    }

    pub fn validate(
        &mut self,
        evidence: &[Evidence],
        validator: UserId,
    ) -> Result<(), DomainError> {
        if self.status != ClaimValidationStatus::Draft || validator == self.authored_by {
            return Err(DomainError::InvalidTransition);
        }
        let all_fixed = self.evidence_ids.iter().all(|required| {
            evidence
                .iter()
                .any(|item| item.id == *required && item.is_publishable())
        });
        if !all_fixed {
            return Err(DomainError::EvidenceNotPublishable);
        }
        self.status = ClaimValidationStatus::Valid;
        self.validated_by = Some(validator);
        self.version += 1;
        Ok(())
    }
}
