#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CorrectionPlan {
    pub prior_revision: u32,
    pub next_revision: u32,
    pub reason: String,
    pub changed_claim_ids: Vec<String>,
}

pub fn plan(
    prior_revision: u32,
    reason: String,
    changed_claim_ids: Vec<String>,
) -> Option<CorrectionPlan> {
    if reason.trim().is_empty() || changed_claim_ids.is_empty() {
        return None;
    }
    Some(CorrectionPlan {
        prior_revision,
        next_revision: prior_revision.saturating_add(1),
        reason,
        changed_claim_ids,
    })
}
