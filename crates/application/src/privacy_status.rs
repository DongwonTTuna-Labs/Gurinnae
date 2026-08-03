use gurine_domain::privacy::{
    PrivacyDigest, PrivacyIdentityState, PrivacyRequestState, PrivacyRequestSummary,
};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::privacy::PrivacyCommandError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyRequestPublicStatus {
    pub request: PrivacyRequestSummary,
    pub decision_reason_code: Option<String>,
    pub decision_receipt_id: Option<Uuid>,
    pub decision_receipt_sha256: Option<PrivacyDigest>,
    pub refusal_notice_receipt_id: Option<Uuid>,
    pub refusal_notice_receipt_sha256: Option<PrivacyDigest>,
    pub notice_receipt_ids: Vec<Uuid>,
    pub notice_receipt_sha256s: Vec<PrivacyDigest>,
    pub next_action_code: PrivacyNextActionCode,
    pub as_of: OffsetDateTime,
}

impl PrivacyRequestPublicStatus {
    pub fn validate(self) -> Result<Self, PrivacyCommandError> {
        let reason_valid = self.decision_reason_code.as_ref().is_none_or(|code| {
            (1..=100).contains(&code.chars().count()) && code.trim() == code && !code.contains('\0')
        });
        let decision_pair_valid = receipt_pair_is_valid(
            self.decision_receipt_id,
            self.decision_receipt_sha256.as_ref(),
        );
        let refusal_pair_valid = receipt_pair_is_valid(
            self.refusal_notice_receipt_id,
            self.refusal_notice_receipt_sha256.as_ref(),
        );
        let notices_valid = self.notice_receipt_ids.len() <= 100
            && self.notice_receipt_ids.len() == self.notice_receipt_sha256s.len()
            && self.notice_receipt_ids.iter().all(|id| !id.is_nil());
        let state_closure_valid = match (self.request.state, self.request.identity_state) {
            (PrivacyRequestState::Received, PrivacyIdentityState::PendingVerification) => {
                self.next_action_code == PrivacyNextActionCode::VerifyIdentity
            }
            (PrivacyRequestState::Received, PrivacyIdentityState::Verified) => {
                self.next_action_code == PrivacyNextActionCode::AwaitReview
            }
            (PrivacyRequestState::Review, PrivacyIdentityState::Verified) => {
                self.next_action_code == PrivacyNextActionCode::AwaitDecision
            }
            (PrivacyRequestState::Approved, PrivacyIdentityState::Verified) => {
                self.next_action_code == PrivacyNextActionCode::AwaitExecution
            }
            (PrivacyRequestState::Rejected, PrivacyIdentityState::Verified) => {
                self.next_action_code == PrivacyNextActionCode::ReviewRefusalNotice
                    && self.decision_receipt_id.is_some()
                    && self.refusal_notice_receipt_id.is_some()
            }
            (PrivacyRequestState::Completed, PrivacyIdentityState::Verified) => {
                self.next_action_code == PrivacyNextActionCode::Complete
                    && self.decision_receipt_id.is_some()
            }
            _ => false,
        };
        if !reason_valid
            || !decision_pair_valid
            || !refusal_pair_valid
            || !notices_valid
            || !state_closure_valid
            || self.as_of < self.request.updated_at
        {
            return Err(PrivacyCommandError::InvalidOwnerResult);
        }
        Ok(self)
    }
}

fn receipt_pair_is_valid(id: Option<Uuid>, digest: Option<&PrivacyDigest>) -> bool {
    match (id, digest) {
        (None, None) => true,
        (Some(id), Some(_)) => !id.is_nil(),
        _ => false,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrivacyNextActionCode {
    VerifyIdentity,
    AwaitReview,
    AwaitDecision,
    AwaitExecution,
    ReviewRefusalNotice,
    Complete,
}

impl PrivacyNextActionCode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::VerifyIdentity => "VERIFY_IDENTITY",
            Self::AwaitReview => "AWAIT_REVIEW",
            Self::AwaitDecision => "AWAIT_DECISION",
            Self::AwaitExecution => "AWAIT_EXECUTION",
            Self::ReviewRefusalNotice => "REVIEW_REFUSAL_NOTICE",
            Self::Complete => "COMPLETE",
        }
    }
}

impl TryFrom<&str> for PrivacyNextActionCode {
    type Error = PrivacyCommandError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "VERIFY_IDENTITY" => Ok(Self::VerifyIdentity),
            "AWAIT_REVIEW" => Ok(Self::AwaitReview),
            "AWAIT_DECISION" => Ok(Self::AwaitDecision),
            "AWAIT_EXECUTION" => Ok(Self::AwaitExecution),
            "REVIEW_REFUSAL_NOTICE" => Ok(Self::ReviewRefusalNotice),
            "COMPLETE" => Ok(Self::Complete),
            _ => Err(PrivacyCommandError::InvalidOwnerResult),
        }
    }
}
