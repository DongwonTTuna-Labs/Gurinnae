use gurine_domain::state_catalog::{InvestigationState, ReviewDecision};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PublicClaim {
    pub text: String,
    pub evidence_ids: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct PublicationCandidate {
    pub investigation_state: InvestigationState,
    pub review_decision: Option<ReviewDecision>,
    pub author_id: String,
    pub reviewer_id: String,
    pub claims: Vec<PublicClaim>,
    pub snapshot_is_current: bool,
    pub response_policy_satisfied: bool,
    pub legal_hold_active: bool,
    pub temporary_restriction_active: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PublicationBlocker {
    InvestigationNotReady,
    HumanApprovalMissing,
    SeparationOfDuties,
    ClaimWithoutEvidence,
    SnapshotStale,
    ResponsePolicyUnsatisfied,
    LegalHold,
    TemporaryRestriction,
}

pub fn evaluate(candidate: &PublicationCandidate) -> Result<(), Vec<PublicationBlocker>> {
    let mut blockers = Vec::new();
    if !matches!(
        candidate.investigation_state,
        InvestigationState::ReadyToPublish | InvestigationState::Closed
    ) {
        blockers.push(PublicationBlocker::InvestigationNotReady);
    }
    if candidate.review_decision != Some(ReviewDecision::Approve) {
        blockers.push(PublicationBlocker::HumanApprovalMissing);
    }
    if candidate.author_id == candidate.reviewer_id {
        blockers.push(PublicationBlocker::SeparationOfDuties);
    }
    if candidate
        .claims
        .iter()
        .any(|claim| claim.evidence_ids.is_empty())
    {
        blockers.push(PublicationBlocker::ClaimWithoutEvidence);
    }
    if !candidate.snapshot_is_current {
        blockers.push(PublicationBlocker::SnapshotStale);
    }
    if !candidate.response_policy_satisfied {
        blockers.push(PublicationBlocker::ResponsePolicyUnsatisfied);
    }
    if candidate.legal_hold_active {
        blockers.push(PublicationBlocker::LegalHold);
    }
    if candidate.temporary_restriction_active {
        blockers.push(PublicationBlocker::TemporaryRestriction);
    }
    if blockers.is_empty() {
        Ok(())
    } else {
        Err(blockers)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automation_cannot_bypass_human_approval() {
        let candidate = PublicationCandidate {
            investigation_state: InvestigationState::ReadyToPublish,
            review_decision: None,
            author_id: "author".to_owned(),
            reviewer_id: "reviewer".to_owned(),
            claims: vec![PublicClaim {
                text: "fact".to_owned(),
                evidence_ids: vec!["E-1".to_owned()],
            }],
            snapshot_is_current: true,
            response_policy_satisfied: true,
            legal_hold_active: false,
            temporary_restriction_active: false,
        };
        assert!(
            matches!(evaluate(&candidate), Err(blockers) if blockers.contains(&PublicationBlocker::HumanApprovalMissing))
        );
    }
}
