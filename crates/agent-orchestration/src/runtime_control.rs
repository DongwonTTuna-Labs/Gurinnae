use super::*;
use thiserror::Error;
use time::OffsetDateTime;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RunStatus {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    BudgetBlocked,
    PolicyBlocked,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ControlState {
    None,
    Active,
    CancelRequested,
    ReconciliationRequired,
    Settled,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum CancelReason {
    UserRequest,
    ObjectiveChanged,
    SourceInvalidated,
    CostStop,
    PolicyStop,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlReceipt {
    pub schema_version: String,
    pub receipt_id: Uuid,
    pub run_id: Uuid,
    pub aggregate_version: i64,
    pub prior_status: RunStatus,
    pub prior_control_state: ControlState,
    pub next_status: RunStatus,
    pub next_control_state: ControlState,
    pub affected_provider_turn_id: Option<Uuid>,
    pub affected_tool_call_id: Option<Uuid>,
    pub reconciliation_evidence_id: Option<Uuid>,
    pub reconciliation_evidence_sha256: Option<String>,
    pub proof_kind: Option<ProofKind>,
    pub proof_sha256: Option<String>,
    pub budget_disposition: String,
    pub budget_resolution_set_sha256: String,
    pub actor_kind: String,
    pub actor_id: String,
    pub reason_code: String,
    pub reason_sha256: String,
    pub prior_receipt_id: Option<Uuid>,
    pub prior_receipt_sha256: Option<String>,
    pub command_binding: String,
    pub audit_event_id: Uuid,
    pub occurred_at: OffsetDateTime,
    #[serde(skip)]
    pub reason: String,
    #[serde(skip)]
    pub proof: Option<ReconciliationProof>,
    pub receipt_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ReconciliationProof {
    pub kind: ProofKind,
    pub accepted_effect: bool,
    pub proof_sha256: String,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ProofKind {
    ProviderLookup,
    IdempotencyLookup,
    ToolAdapterLookup,
    CostUsageReceipt,
    DefinitiveNoDispatch,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RunControl {
    pub run_id: Uuid,
    pub version: i64,
    pub status: RunStatus,
    pub control_state: ControlState,
    pub receipts: Vec<ControlReceipt>,
}
impl RunControl {
    pub fn new(run_id: Uuid) -> Self {
        Self {
            run_id,
            version: 1,
            status: RunStatus::Queued,
            control_state: ControlState::None,
            receipts: Vec::new(),
        }
    }
    pub fn cancel(
        &mut self,
        expected_version: i64,
        reason: CancelReason,
        reason_text: String,
    ) -> Result<ControlReceipt, RuntimeError> {
        if self.version != expected_version || self.control_state == ControlState::Settled {
            return Err(RuntimeError::VersionConflict);
        }
        let prior_status = self.status;
        let prior_control_state = self.control_state;
        let (next_status, next_control_state) = match (self.status, self.control_state) {
            (RunStatus::Queued, ControlState::None) => {
                (RunStatus::Cancelled, ControlState::Settled)
            }
            (RunStatus::Running, ControlState::Active | ControlState::ReconciliationRequired) => {
                (RunStatus::Running, ControlState::CancelRequested)
            }
            _ => return Err(RuntimeError::InvalidTransition),
        };
        self.version = self
            .version
            .checked_add(1)
            .ok_or(RuntimeError::VersionConflict)?;
        self.status = next_status;
        self.control_state = next_control_state;
        let receipt = self.receipt(
            prior_status,
            prior_control_state,
            next_status,
            next_control_state,
            reason_text,
            None,
        )?;
        self.receipts.push(receipt.clone());
        let _ = reason;
        Ok(receipt)
    }

    /// Records a possible external effect without guessing its outcome.  A
    /// timeout after dispatch must use this state; elapsed time is not proof
    /// of failure, cancellation, or success.
    pub fn mark_reconciliation_required(
        &mut self,
        expected_version: i64,
    ) -> Result<ControlReceipt, RuntimeError> {
        if self.version != expected_version
            || self.status != RunStatus::Running
            || self.control_state != ControlState::Active
        {
            return Err(RuntimeError::VersionConflict);
        }
        let prior_status = self.status;
        let prior_control_state = self.control_state;
        self.version = self
            .version
            .checked_add(1)
            .ok_or(RuntimeError::VersionConflict)?;
        self.control_state = ControlState::ReconciliationRequired;
        let receipt = self.receipt(
            prior_status,
            prior_control_state,
            self.status,
            self.control_state,
            "possible external effect".to_owned(),
            None,
        )?;
        self.receipts.push(receipt.clone());
        Ok(receipt)
    }
    pub fn reconcile(
        &mut self,
        expected_version: i64,
        proof: ReconciliationProof,
    ) -> Result<ControlReceipt, RuntimeError> {
        if self.version != expected_version || !is_sha256(&proof.proof_sha256) {
            return Err(RuntimeError::VersionConflict);
        }
        let prior_status = self.status;
        let prior_control_state = self.control_state;
        if !matches!(
            (self.status, self.control_state),
            (
                RunStatus::Running,
                ControlState::CancelRequested | ControlState::ReconciliationRequired
            )
        ) {
            return Err(RuntimeError::InvalidTransition);
        }
        let (next_status, next_control_state) = if proof.accepted_effect {
            (RunStatus::Succeeded, ControlState::Settled)
        } else if self.control_state == ControlState::CancelRequested {
            (RunStatus::Cancelled, ControlState::Settled)
        } else {
            (RunStatus::Running, ControlState::Active)
        };
        self.version = self
            .version
            .checked_add(1)
            .ok_or(RuntimeError::VersionConflict)?;
        self.status = next_status;
        self.control_state = next_control_state;
        let receipt = self.receipt(
            prior_status,
            prior_control_state,
            next_status,
            next_control_state,
            "reconciliation".to_owned(),
            Some(proof),
        )?;
        self.receipts.push(receipt.clone());
        Ok(receipt)
    }
    fn receipt(
        &self,
        prior_status: RunStatus,
        prior_control_state: ControlState,
        next_status: RunStatus,
        next_control_state: ControlState,
        reason: String,
        proof: Option<ReconciliationProof>,
    ) -> Result<ControlReceipt, RuntimeError> {
        let mut receipt = ControlReceipt {
            schema_version: "agent-run-control-receipt.v2".to_owned(),
            receipt_id: Uuid::new_v4(),
            run_id: self.run_id,
            aggregate_version: self.version,
            prior_status,
            prior_control_state,
            next_status,
            next_control_state,
            affected_provider_turn_id: None,
            affected_tool_call_id: None,
            reconciliation_evidence_id: None,
            reconciliation_evidence_sha256: proof.as_ref().map(|value| value.proof_sha256.clone()),
            proof_kind: proof.as_ref().map(|value| value.kind),
            proof_sha256: proof.as_ref().map(|value| value.proof_sha256.clone()),
            budget_disposition: "NONE".to_owned(),
            budget_resolution_set_sha256: sha256_hex(b"NONE"),
            actor_kind: "RUNTIME".to_owned(),
            actor_id: self.run_id.to_string(),
            reason_code: "CONTROL_REQUEST".to_owned(),
            reason_sha256: sha256_hex(reason.as_bytes()),
            prior_receipt_id: self.receipts.last().map(|value| value.receipt_id),
            prior_receipt_sha256: self
                .receipts
                .last()
                .map(|value| value.receipt_sha256.clone()),
            command_binding: "agent-run-control.v2".to_owned(),
            audit_event_id: Uuid::new_v4(),
            occurred_at: OffsetDateTime::now_utc(),
            reason,
            proof,
            receipt_sha256: String::new(),
        };
        receipt.receipt_sha256 = digest_without_digest(&receipt)?;
        Ok(receipt)
    }
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum RuntimeError {
    #[error("invalid digest")]
    InvalidDigest,
    #[error("transcript conflict")]
    TranscriptConflict,
    #[error("version conflict")]
    VersionConflict,
    #[error("invalid state transition")]
    InvalidTransition,
    #[error("serialization failure")]
    Serialization,
    #[error("provider is unavailable")]
    ProviderUnavailable,
    #[error("provider receipt is invalid")]
    InvalidProviderReceipt,
    #[error("tool is denied")]
    ToolDenied,
    #[error("tool call limit exceeded")]
    ToolLimitExceeded,
}
