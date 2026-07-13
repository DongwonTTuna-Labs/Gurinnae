use serde::{Deserialize, Serialize};

use crate::{
    error::{DomainError, validated_text},
    ids::{CaseId, SignalId, UserId},
    state_catalog::SignalStatus,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DetectionSignal {
    pub id: SignalId,
    pub rule_id: String,
    pub rule_version: i64,
    pub input_digest: String,
    pub summary: String,
    pub status: SignalStatus,
    pub assigned_to: Option<UserId>,
    pub linked_case_id: Option<CaseId>,
}

impl DetectionSignal {
    pub fn new(
        id: SignalId,
        rule_id: impl Into<String>,
        rule_version: i64,
        input_digest: String,
        summary: impl Into<String>,
    ) -> Result<Self, DomainError> {
        if rule_version < 1 || !is_hash(&input_digest) {
            return Err(DomainError::InvalidIdentifier);
        }
        Ok(Self {
            id,
            rule_id: validated_text(rule_id, 200)?,
            rule_version,
            input_digest,
            summary: validated_text(summary, 2_000)?,
            status: SignalStatus::New,
            assigned_to: None,
            linked_case_id: None,
        })
    }

    pub fn assign(&mut self, assignee: UserId) -> Result<(), DomainError> {
        if !matches!(
            self.status,
            SignalStatus::New | SignalStatus::NeedsData | SignalStatus::Assigned
        ) {
            return Err(DomainError::InvalidTransition);
        }
        self.assigned_to = Some(assignee);
        self.status = SignalStatus::Assigned;
        Ok(())
    }

    pub fn link_case(&mut self, case_id: CaseId) -> Result<(), DomainError> {
        if !matches!(
            self.status,
            SignalStatus::New | SignalStatus::Assigned | SignalStatus::NeedsData
        ) {
            return Err(DomainError::InvalidTransition);
        }
        self.linked_case_id = Some(case_id);
        self.status = SignalStatus::Linked;
        Ok(())
    }
}

fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
