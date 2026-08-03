use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{Failure, canonical_bytes, sha256};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RelayUpgradeAttemptKind {
    Manual,
    Auto,
}

impl RelayUpgradeAttemptKind {
    pub(super) fn parse(value: &str) -> Result<Self, Failure> {
        match value {
            "MANUAL" => Ok(Self::Manual),
            "AUTO" => Ok(Self::Auto),
            _ => Err(receipt_error("attemptKind")),
        }
    }

    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Manual => "MANUAL",
            Self::Auto => "AUTO",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RelayUpgradeReceiptOutcome {
    Applied,
    Failed,
    Suppressed,
}

impl RelayUpgradeReceiptOutcome {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Applied => "APPLIED",
            Self::Failed => "FAILED",
            Self::Suppressed => "SUPPRESSED",
        }
    }
}

pub(super) struct RelayUpgradeReceiptInput {
    pub(super) receipt_id: Uuid,
    pub(super) attempt_id: Uuid,
    pub(super) provider_id: Uuid,
    pub(super) target_model_id: String,
    pub(super) attempt_kind: RelayUpgradeAttemptKind,
    pub(super) outcome: RelayUpgradeReceiptOutcome,
    pub(super) before_provider_version: i64,
    pub(super) after_provider_version: i64,
    pub(super) before_model_id: Option<String>,
    pub(super) after_model_id: Option<String>,
    pub(super) policy_sha256: Option<String>,
    pub(super) gateway_receipt_sha256: Option<String>,
    pub(super) usage_evidence_sha256: Option<String>,
    pub(super) audit_event_id: Option<Uuid>,
    pub(super) incident_event_id: Option<Uuid>,
    pub(super) cost_event_id: Option<Uuid>,
    pub(super) recorded_at: OffsetDateTime,
}

pub(super) struct RelayUpgradeReceipt {
    pub(super) receipt_id: Uuid,
    pub(super) attempt_kind: RelayUpgradeAttemptKind,
    pub(super) outcome: RelayUpgradeReceiptOutcome,
    pub(super) receipt_canonical: Vec<u8>,
    pub(super) canonical_receipt: serde_json::Value,
    pub(super) receipt_sha256: String,
    pub(super) recorded_at: OffsetDateTime,
}

impl RelayUpgradeReceipt {
    pub(super) fn build(input: RelayUpgradeReceiptInput) -> Result<Self, Failure> {
        validate_receipt_input(&input)?;
        let recorded_at_text = input
            .recorded_at
            .format(&Rfc3339)
            .map_err(|error| receipt_error(error.to_string()))?;
        let canonical_receipt = serde_json::json!({
            "schemaVersion":"provider-model-upgrade-receipt.v1",
            "receiptId":input.receipt_id,
            "attemptId":input.attempt_id,
            "providerId":input.provider_id,
            "targetModelId":input.target_model_id,
            "attemptKind":input.attempt_kind.as_str(),
            "outcome":input.outcome.as_str(),
            "beforeProviderVersion":input.before_provider_version,
            "afterProviderVersion":input.after_provider_version,
            "beforeModelId":input.before_model_id,
            "afterModelId":input.after_model_id,
            "policySha256":input.policy_sha256,
            "gatewayReceiptSha256":input.gateway_receipt_sha256,
            "usageEvidenceSha256":input.usage_evidence_sha256,
            "auditEventId":input.audit_event_id,
            "incidentEventId":input.incident_event_id,
            "costEventId":input.cost_event_id,
            "recordedAt":recorded_at_text,
        });
        let receipt_canonical = canonical_bytes(&canonical_receipt)?;
        let receipt_sha256 = sha256(&receipt_canonical);
        Ok(Self {
            receipt_id: input.receipt_id,
            attempt_kind: input.attempt_kind,
            outcome: input.outcome,
            receipt_canonical,
            canonical_receipt,
            receipt_sha256,
            recorded_at: input.recorded_at,
        })
    }
}

fn validate_receipt_input(input: &RelayUpgradeReceiptInput) -> Result<(), Failure> {
    let same_version_and_model = input.after_provider_version == input.before_provider_version
        && input.after_model_id == input.before_model_id;
    let valid = match input.outcome {
        RelayUpgradeReceiptOutcome::Applied => {
            input.after_provider_version == input.before_provider_version.saturating_add(1)
                && input.after_model_id.as_deref() == Some(input.target_model_id.as_str())
                && input.policy_sha256.is_some()
                && input.gateway_receipt_sha256.is_some()
                && input.usage_evidence_sha256.is_some()
                && input.audit_event_id.is_some()
                && input.incident_event_id.is_none()
                && input.cost_event_id.is_some()
        }
        RelayUpgradeReceiptOutcome::Failed => {
            same_version_and_model
                && match input.attempt_kind {
                    RelayUpgradeAttemptKind::Auto => {
                        input.audit_event_id.is_some() && input.incident_event_id.is_some()
                    }
                    RelayUpgradeAttemptKind::Manual => {
                        input.audit_event_id.is_none() && input.incident_event_id.is_none()
                    }
                }
        }
        RelayUpgradeReceiptOutcome::Suppressed => {
            input.attempt_kind == RelayUpgradeAttemptKind::Auto
                && same_version_and_model
                && input.gateway_receipt_sha256.is_none()
                && input.usage_evidence_sha256.is_none()
                && input.audit_event_id.is_none()
                && input.incident_event_id.is_none()
                && input.cost_event_id.is_none()
        }
    };
    if valid {
        Ok(())
    } else {
        Err(receipt_error("outcome binding"))
    }
}

fn receipt_error(detail: impl Into<String>) -> Failure {
    Failure::Terminal("PROVIDER_MODEL_UPGRADE_RECEIPT_INVALID", detail.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_invalid(input: RelayUpgradeReceiptInput) {
        assert!(matches!(
            RelayUpgradeReceipt::build(input),
            Err(Failure::Terminal(
                "PROVIDER_MODEL_UPGRADE_RECEIPT_INVALID",
                _
            ))
        ));
    }

    fn input(
        attempt_kind: RelayUpgradeAttemptKind,
        outcome: RelayUpgradeReceiptOutcome,
    ) -> RelayUpgradeReceiptInput {
        let auto_failed = attempt_kind == RelayUpgradeAttemptKind::Auto
            && outcome == RelayUpgradeReceiptOutcome::Failed;
        let applied = outcome == RelayUpgradeReceiptOutcome::Applied;
        RelayUpgradeReceiptInput {
            receipt_id: Uuid::from_u128(1),
            attempt_id: Uuid::from_u128(2),
            provider_id: Uuid::from_u128(3),
            target_model_id: "relay-v2".to_owned(),
            attempt_kind,
            outcome,
            before_provider_version: 7,
            after_provider_version: if applied { 8 } else { 7 },
            before_model_id: Some("relay-v1".to_owned()),
            after_model_id: Some(if applied { "relay-v2" } else { "relay-v1" }.to_owned()),
            policy_sha256: applied.then(|| sha256(b"policy")),
            gateway_receipt_sha256: applied.then(|| sha256(b"gateway")),
            usage_evidence_sha256: applied.then(|| sha256(b"usage")),
            audit_event_id: (applied || auto_failed).then(|| Uuid::from_u128(4)),
            incident_event_id: auto_failed.then(|| Uuid::from_u128(5)),
            cost_event_id: applied.then(|| Uuid::from_u128(6)),
            recorded_at: OffsetDateTime::from_unix_timestamp(1_784_188_800)
                .expect("test timestamp"),
        }
    }

    #[test]
    fn all_outcomes_share_one_canonical_byte_builder() {
        for (kind, outcome) in [
            (
                RelayUpgradeAttemptKind::Manual,
                RelayUpgradeReceiptOutcome::Applied,
            ),
            (
                RelayUpgradeAttemptKind::Auto,
                RelayUpgradeReceiptOutcome::Failed,
            ),
            (
                RelayUpgradeAttemptKind::Auto,
                RelayUpgradeReceiptOutcome::Suppressed,
            ),
        ] {
            let receipt =
                RelayUpgradeReceipt::build(input(kind, outcome)).expect("valid typed receipt");
            assert_eq!(sha256(&receipt.receipt_canonical), receipt.receipt_sha256);
            assert_eq!(
                serde_json::from_slice::<serde_json::Value>(&receipt.receipt_canonical)
                    .expect("canonical JSON"),
                receipt.canonical_receipt,
            );
        }
    }

    #[test]
    fn auto_applied_receipt_requires_the_success_gate_fence_and_evidence() {
        let applied = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        assert!(RelayUpgradeReceipt::build(applied).is_ok());

        let mut stale_version = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        stale_version.after_provider_version = stale_version.before_provider_version;
        assert_invalid(stale_version);

        let mut wrong_model = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        wrong_model.after_model_id = Some("relay-other".to_owned());
        assert_invalid(wrong_model);

        let mut missing_policy = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        missing_policy.policy_sha256 = None;
        assert_invalid(missing_policy);

        let mut missing_gateway = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        missing_gateway.gateway_receipt_sha256 = None;
        assert_invalid(missing_gateway);

        let mut missing_usage = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        missing_usage.usage_evidence_sha256 = None;
        assert_invalid(missing_usage);

        let mut missing_audit = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        missing_audit.audit_event_id = None;
        assert_invalid(missing_audit);

        let mut missing_cost = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Applied,
        );
        missing_cost.cost_event_id = None;
        assert_invalid(missing_cost);
    }

    #[test]
    fn auto_failed_receipt_requires_the_failure_gate_without_applying() {
        let failed = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Failed,
        );
        assert!(RelayUpgradeReceipt::build(failed).is_ok());

        let mut changed_version = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Failed,
        );
        changed_version.after_provider_version += 1;
        assert_invalid(changed_version);

        let mut changed_model = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Failed,
        );
        changed_model.after_model_id = Some("relay-v2".to_owned());
        assert_invalid(changed_model);

        let mut missing_audit = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Failed,
        );
        missing_audit.audit_event_id = None;
        assert_invalid(missing_audit);

        let mut missing_incident = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Failed,
        );
        missing_incident.incident_event_id = None;
        assert_invalid(missing_incident);
    }

    #[test]
    fn failure_event_binding_is_attempt_kind_specific() {
        let mut manual = input(
            RelayUpgradeAttemptKind::Manual,
            RelayUpgradeReceiptOutcome::Failed,
        );
        manual.audit_event_id = Some(Uuid::from_u128(9));
        assert!(RelayUpgradeReceipt::build(manual).is_err());
        let mut auto = input(
            RelayUpgradeAttemptKind::Auto,
            RelayUpgradeReceiptOutcome::Failed,
        );
        auto.audit_event_id = None;
        assert!(RelayUpgradeReceipt::build(auto).is_err());
    }
}
