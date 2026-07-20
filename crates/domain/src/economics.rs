//! Typed business/economics aggregates shared by the persistence and API
//! layers.  These types intentionally do not expose arbitrary JSON payloads:
//! an economic claim is either backed by a closed receipt or remains typed
//! UNKNOWN/BLOCKED.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{error::DomainError, money::Money};

pub const QUALIFICATION_CRITERION_COUNT: usize = 13;
pub const PAID_PACKET_MEMBER_COUNT: usize = 10;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum QualificationEffect {
    Original,
    Replacement,
    Reversal,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct QualificationReceipt {
    pub id: Uuid,
    pub qualification_episode_id: Uuid,
    pub revision: i64,
    pub effect: QualificationEffect,
    pub criteria: [bool; QUALIFICATION_CRITERION_COUNT],
    pub first_qualified_at: OffsetDateTime,
    pub decision_effective_at: OffsetDateTime,
    pub recorded_at: OffsetDateTime,
    pub receipt_digest: String,
}

impl QualificationReceipt {
    pub fn validate(&self, predecessor: Option<&Self>) -> Result<(), DomainError> {
        if self.receipt_digest.len() != 64
            || !self
                .receipt_digest
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            || self.revision < 1
            || self.decision_effective_at > self.recorded_at
        {
            return Err(DomainError::InvalidTransition);
        }
        match (self.effect, predecessor) {
            (QualificationEffect::Original, None)
                if self.revision == 1
                    && self.criteria.iter().all(|criterion| *criterion)
                    && self.first_qualified_at == self.decision_effective_at =>
            {
                Ok(())
            }
            (QualificationEffect::Replacement | QualificationEffect::Reversal, Some(previous))
                if self.revision == previous.revision + 1
                    && self.qualification_episode_id == previous.qualification_episode_id
                    && self.first_qualified_at == previous.first_qualified_at
                    && self.decision_effective_at > previous.decision_effective_at =>
            {
                Ok(())
            }
            _ => Err(DomainError::InvalidTransition),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PaidPacketState {
    AwaitingTerminalBinding,
    Finalized,
    Invalidated,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PaidTerminalState {
    Delivered,
    Read,
    RejectedFinal,
    EffectSucceeded,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PaidEvidencePacket {
    pub packet_id: Uuid,
    pub packet_version: i64,
    pub state: PaidPacketState,
    pub member_set_digest: String,
    pub member_count: usize,
    pub terminal: Option<PaidTerminalState>,
    pub packet_digest: Option<String>,
}

impl PaidEvidencePacket {
    pub fn bind_terminal(
        &mut self,
        terminal: PaidTerminalState,
        packet_digest: String,
    ) -> Result<(), DomainError> {
        if self.state != PaidPacketState::AwaitingTerminalBinding
            || self.member_count != PAID_PACKET_MEMBER_COUNT
            || !is_digest(&self.member_set_digest)
            || !is_digest(&packet_digest)
        {
            return Err(DomainError::EvidenceNotPublishable);
        }
        self.state = PaidPacketState::Finalized;
        self.terminal = Some(terminal);
        self.packet_digest = Some(packet_digest);
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MetricStatus {
    Known,
    Unknown,
    NotApplicable,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct MetricValue<T> {
    pub status: MetricStatus,
    pub value: Option<T>,
    pub reason_code: String,
    pub evidence_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CacResult {
    pub metric: MetricValue<Money>,
    pub qualified_episode_count: u64,
    pub unattributed_amount: Option<Money>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PaybackResult {
    pub metric: MetricValue<Decimal>,
    pub contribution_months: u8,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CommercialReadiness {
    pub state: MetricStatus,
    pub blockers: Vec<String>,
    pub evaluation_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BusinessMetricSnapshot {
    pub metric_id: String,
    pub metric_version: i64,
    pub status: MetricStatus,
    pub reason_code: String,
    pub formula_digest: String,
    pub policy_digest: String,
    pub input_set_digest: String,
    pub eligible_count: u64,
    pub pending_count: u64,
    pub unknown_count: u64,
    pub latest_source_at: Option<OffsetDateTime>,
    pub fresh_until: Option<OffsetDateTime>,
    pub breach_action: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BusinessFunnelStage {
    pub stage: String,
    pub state: String,
    pub organization_count: u64,
    pub unknown_count: u64,
    pub evidence_set_digest: String,
    pub owner_function: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BusinessHealth {
    pub as_of: OffsetDateTime,
    pub readiness: CommercialReadiness,
    pub paid_value: MetricValue<u64>,
    pub activation_p90_hours: MetricValue<Decimal>,
    pub cac: CacResult,
    pub payback: PaybackResult,
    pub specification_version: String,
    pub metric_catalog_digest: String,
    pub funnel: Vec<BusinessFunnelStage>,
    pub metrics: Vec<BusinessMetricSnapshot>,
    pub top_issue: Option<String>,
    pub unknown_source_count: u64,
    pub next_review_at: OffsetDateTime,
}

fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digest() -> String {
        "a".repeat(64)
    }

    #[test]
    fn qualification_requires_all_ordered_criteria() {
        let now = OffsetDateTime::UNIX_EPOCH;
        let mut receipt = QualificationReceipt {
            id: Uuid::nil(),
            qualification_episode_id: Uuid::nil(),
            revision: 1,
            effect: QualificationEffect::Original,
            criteria: [true; QUALIFICATION_CRITERION_COUNT],
            first_qualified_at: now,
            decision_effective_at: now,
            recorded_at: now,
            receipt_digest: digest(),
        };
        assert!(receipt.validate(None).is_ok());
        receipt.criteria[6] = false;
        assert_eq!(receipt.validate(None), Err(DomainError::InvalidTransition));
    }

    #[test]
    fn paid_packet_needs_all_members_before_terminal() {
        let mut packet = PaidEvidencePacket {
            packet_id: Uuid::nil(),
            packet_version: 1,
            state: PaidPacketState::AwaitingTerminalBinding,
            member_set_digest: digest(),
            member_count: PAID_PACKET_MEMBER_COUNT - 1,
            terminal: None,
            packet_digest: None,
        };
        assert!(
            packet
                .bind_terminal(PaidTerminalState::Delivered, digest())
                .is_err()
        );
        packet.member_count = PAID_PACKET_MEMBER_COUNT;
        assert!(
            packet
                .bind_terminal(PaidTerminalState::Delivered, digest())
                .is_ok()
        );
        assert_eq!(packet.state, PaidPacketState::Finalized);
    }
}
