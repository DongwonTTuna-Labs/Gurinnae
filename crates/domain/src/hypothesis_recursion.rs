use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use time::Duration;
use uuid::Uuid;

use crate::{
    error::{DomainError, validated_text},
    ids::{CaseId, JobId, UserId},
};

macro_rules! recursion_id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            pub fn try_new(value: Uuid) -> Result<Self, DomainError> {
                if value.is_nil() {
                    return Err(DomainError::InvalidIdentifier);
                }
                Ok(Self(value))
            }

            pub const fn value(self) -> Uuid {
                self.0
            }
        }
    };
}

macro_rules! closed_enum {
    ($name:ident { $($variant:ident => $value:literal),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
        #[serde(rename_all = "SCREAMING_SNAKE_CASE")]
        pub enum $name {
            $($variant),+
        }

        impl $name {
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $value),+
                }
            }
        }

        impl TryFrom<&str> for $name {
            type Error = DomainError;

            fn try_from(value: &str) -> Result<Self, Self::Error> {
                match value {
                    $($value => Ok(Self::$variant)),+,
                    _ => Err(DomainError::InvalidIdentifier),
                }
            }
        }
    };
}

recursion_id!(HypothesisRecursionPolicyId);
recursion_id!(HypothesisRecursionPlanId);
recursion_id!(HypothesisRecursionNodeId);
recursion_id!(HypothesisRecursionTransitionId);
recursion_id!(HypothesisRecursionReceiptId);
recursion_id!(HypothesisRecursionBudgetLedgerId);
recursion_id!(HypothesisExecutionId);
recursion_id!(HypothesisRecursionAgentRunId);
recursion_id!(HypothesisRecursionSnapshotId);

closed_enum!(HypothesisRecursionTriggerKind {
    ActionExecution => "ACTION_EXECUTION",
    AgentRun => "AGENT_RUN",
});
closed_enum!(HypothesisRecursionStage {
    MarketResearcher => "MARKET_RESEARCHER",
    Skeptic => "SKEPTIC",
});
closed_enum!(HypothesisRecursionPlanState {
    Active => "ACTIVE",
    ReviewedTerminal => "REVIEWED_TERMINAL",
    BudgetExhausted => "BUDGET_EXHAUSTED",
});
closed_enum!(HypothesisRecursionNodeState {
    Queued => "QUEUED",
    Succeeded => "SUCCEEDED",
    Failed => "FAILED",
    BudgetBlocked => "BUDGET_BLOCKED",
});
closed_enum!(HypothesisRecursionBudgetEntryKind {
    Reserve => "RESERVE",
    Settle => "SETTLE",
    Release => "RELEASE",
});
closed_enum!(HypothesisRecursionProviderClassification {
    Public => "PUBLIC",
    Internal => "INTERNAL",
});
closed_enum!(HypothesisRecursionDisposition {
    Started => "STARTED",
    PolicyAbsent => "POLICY_ABSENT",
    PolicyDisabled => "POLICY_DISABLED",
    MaxDepthReached => "MAX_DEPTH_REACHED",
    CaseBudgetBlocked => "CASE_BUDGET_BLOCKED",
    NotHypothesis => "NOT_HYPOTHESIS",
    NotSucceeded => "NOT_SUCCEEDED",
    NodeNotRecursive => "NODE_NOT_RECURSIVE",
    StageNotMarketResearcher => "STAGE_NOT_MARKET_RESEARCHER",
    RunNotSucceeded => "RUN_NOT_SUCCEEDED",
    PlanTerminal => "PLAN_TERMINAL",
});

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct HypothesisRecursionDigest(String);

impl HypothesisRecursionDigest {
    pub fn try_new(value: impl Into<String>) -> Result<Self, DomainError> {
        let value = value.into();
        if value.len() != 64
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(DomainError::InvalidIdentifier);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionPolicyLimits {
    pub max_depth: u8,
    pub case_budget_micros_krw: u64,
    pub market_researcher_stage_budget_micros_krw: u64,
    pub skeptic_stage_budget_micros_krw: u64,
    pub max_provider_turns: u8,
    pub max_tool_calls: u8,
    pub deadline: Duration,
}

impl HypothesisRecursionPolicyLimits {
    pub fn validate(self) -> Result<Self, DomainError> {
        if !(1..=16).contains(&self.max_depth)
            || self.case_budget_micros_krw == 0
            || self.market_researcher_stage_budget_micros_krw == 0
            || self.skeptic_stage_budget_micros_krw == 0
            || !(1..=32).contains(&self.max_provider_turns)
            || self.max_tool_calls > 32
            || !self.deadline.is_positive()
        {
            return Err(DomainError::InvalidTransition);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionProviderPolicy {
    pub version: String,
    pub digest: HypothesisRecursionDigest,
    pub classification: HypothesisRecursionProviderClassification,
    pub candidate_ids: Vec<String>,
}

impl HypothesisRecursionProviderPolicy {
    pub fn try_new(
        version: impl Into<String>,
        digest: HypothesisRecursionDigest,
        classification: HypothesisRecursionProviderClassification,
        candidate_ids: Vec<String>,
    ) -> Result<Self, DomainError> {
        let version = validated_text(version, 200)?;
        let unique = candidate_ids.iter().collect::<BTreeSet<_>>();
        if !(1..=8).contains(&candidate_ids.len())
            || unique.len() != candidate_ids.len()
            || candidate_ids
                .iter()
                .any(|candidate| !valid_candidate(candidate))
        {
            return Err(DomainError::InvalidIdentifier);
        }
        Ok(Self {
            version,
            digest,
            classification,
            candidate_ids,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionStageContract {
    pub stage: HypothesisRecursionStage,
    pub prompt_id: String,
    pub prompt_version: String,
    pub prompt_digest: HypothesisRecursionDigest,
    pub output_schema_id: String,
    pub output_schema_version: String,
    pub output_schema_digest: HypothesisRecursionDigest,
}

impl HypothesisRecursionStageContract {
    pub fn try_new(
        stage: HypothesisRecursionStage,
        prompt: (&str, &str, HypothesisRecursionDigest),
        output_schema: (&str, &str, HypothesisRecursionDigest),
    ) -> Result<Self, DomainError> {
        Ok(Self {
            stage,
            prompt_id: validated_text(prompt.0, 200)?,
            prompt_version: validated_text(prompt.1, 200)?,
            prompt_digest: prompt.2,
            output_schema_id: validated_text(output_schema.0, 200)?,
            output_schema_version: validated_text(output_schema.1, 200)?,
            output_schema_digest: output_schema.2,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionPolicy {
    pub id: HypothesisRecursionPolicyId,
    pub version: i64,
    pub enabled: bool,
    pub limits: HypothesisRecursionPolicyLimits,
    pub provider: HypothesisRecursionProviderPolicy,
    pub budget_policy_version: String,
    pub budget_policy_digest: HypothesisRecursionDigest,
    pub market_researcher: HypothesisRecursionStageContract,
    pub skeptic: HypothesisRecursionStageContract,
    pub created_by: UserId,
    pub digest: HypothesisRecursionDigest,
}

impl HypothesisRecursionPolicy {
    pub fn validate(mut self) -> Result<Self, DomainError> {
        self.limits = self.limits.validate()?;
        self.budget_policy_version = validated_text(self.budget_policy_version, 200)?;
        if self.version < 1
            || self.created_by.value().is_nil()
            || self.market_researcher.stage != HypothesisRecursionStage::MarketResearcher
            || self.skeptic.stage != HypothesisRecursionStage::Skeptic
        {
            return Err(DomainError::InvalidTransition);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionPlan {
    pub id: HypothesisRecursionPlanId,
    pub case_id: CaseId,
    pub root_execution_id: HypothesisExecutionId,
    pub root_execution_generation: i64,
    pub root_execution_digest: HypothesisRecursionDigest,
    pub snapshot_id: HypothesisRecursionSnapshotId,
    pub snapshot_digest: HypothesisRecursionDigest,
    pub policy_id: HypothesisRecursionPolicyId,
    pub policy_version: i64,
    pub policy_digest: HypothesisRecursionDigest,
    pub max_depth: u8,
    pub case_budget_micros_krw: u64,
    pub digest: HypothesisRecursionDigest,
}

impl HypothesisRecursionPlan {
    pub fn validate(self) -> Result<Self, DomainError> {
        if self.case_id.value().is_nil()
            || self.root_execution_generation < 1
            || self.policy_version < 1
            || !(1..=16).contains(&self.max_depth)
            || self.case_budget_micros_krw == 0
        {
            return Err(DomainError::InvalidTransition);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionNode {
    pub id: HypothesisRecursionNodeId,
    pub plan_id: HypothesisRecursionPlanId,
    pub parent: Option<(HypothesisRecursionNodeId, u8)>,
    pub case_id: CaseId,
    pub depth: u8,
    pub stage: HypothesisRecursionStage,
    pub execution_digest: HypothesisRecursionDigest,
    pub snapshot_id: HypothesisRecursionSnapshotId,
    pub snapshot_digest: HypothesisRecursionDigest,
    pub agent_run_id: HypothesisRecursionAgentRunId,
    pub job_id: JobId,
    pub reserved_micros_krw: u64,
    pub dedupe_digest: HypothesisRecursionDigest,
    pub digest: HypothesisRecursionDigest,
}

impl HypothesisRecursionNode {
    pub fn validate(self) -> Result<Self, DomainError> {
        let parent_valid = match (self.depth, self.parent) {
            (1, None) => true,
            (depth, Some((_, parent_depth))) if depth > 1 => {
                parent_depth.checked_add(1) == Some(depth)
            }
            _ => false,
        };
        if !parent_valid
            || self.depth > 16
            || self.case_id.value().is_nil()
            || self.job_id.value().is_nil()
            || self.reserved_micros_krw == 0
        {
            return Err(DomainError::InvalidTransition);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionChainLink {
    pub sequence: i64,
    pub prior: Option<(i64, HypothesisRecursionDigest)>,
}

impl HypothesisRecursionChainLink {
    pub fn validate(self) -> Result<Self, DomainError> {
        let valid = match (&self.prior, self.sequence) {
            (None, 1) => true,
            (Some((prior_sequence, _)), sequence) if sequence > 1 => {
                *prior_sequence == sequence - 1
            }
            _ => false,
        };
        if !valid {
            return Err(DomainError::InvalidTransition);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HypothesisRecursionTransitionScope {
    Plan(HypothesisRecursionPlanState),
    Node {
        node_id: HypothesisRecursionNodeId,
        stage: HypothesisRecursionStage,
        next_state: HypothesisRecursionNodeState,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionTransition {
    pub id: HypothesisRecursionTransitionId,
    pub plan_id: HypothesisRecursionPlanId,
    pub chain: HypothesisRecursionChainLink,
    pub scope: HypothesisRecursionTransitionScope,
    pub proof_digest: HypothesisRecursionDigest,
    pub receipt_digest: HypothesisRecursionDigest,
}

impl HypothesisRecursionTransition {
    pub fn validate(mut self) -> Result<Self, DomainError> {
        self.chain = self.chain.validate()?;
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionStarted {
    pub plan_id: HypothesisRecursionPlanId,
    pub node_id: HypothesisRecursionNodeId,
    pub agent_run_id: HypothesisRecursionAgentRunId,
    pub job_id: JobId,
}

impl HypothesisRecursionStarted {
    pub fn try_new(
        plan_id: Uuid,
        node_id: Uuid,
        agent_run_id: Uuid,
        job_id: Uuid,
    ) -> Result<Self, DomainError> {
        if job_id.is_nil() {
            return Err(DomainError::InvalidIdentifier);
        }
        Ok(Self {
            plan_id: HypothesisRecursionPlanId::try_new(plan_id)?,
            node_id: HypothesisRecursionNodeId::try_new(node_id)?,
            agent_run_id: HypothesisRecursionAgentRunId::try_new(agent_run_id)?,
            job_id: JobId::new(job_id),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionReceipt {
    pub id: HypothesisRecursionReceiptId,
    pub trigger_kind: HypothesisRecursionTriggerKind,
    pub trigger_id: Uuid,
    pub trigger_generation: i64,
    pub trigger_digest: HypothesisRecursionDigest,
    pub trigger_receipt_digest: HypothesisRecursionDigest,
    pub producer_job_id: JobId,
    pub policy: Option<(HypothesisRecursionPolicyId, i64)>,
    pub disposition: HypothesisRecursionDisposition,
    pub started: Option<HypothesisRecursionStarted>,
    pub digest: HypothesisRecursionDigest,
}

impl HypothesisRecursionReceipt {
    pub fn validate(self) -> Result<Self, DomainError> {
        let shape_valid = match self.disposition {
            HypothesisRecursionDisposition::Started => {
                self.policy.is_some() && self.started.is_some()
            }
            _ => self.started.is_none(),
        };
        if self.trigger_id.is_nil()
            || self.trigger_generation < 1
            || self.producer_job_id.value().is_nil()
            || self.policy.is_some_and(|(_, version)| version < 1)
            || !shape_valid
        {
            return Err(DomainError::InvalidTransition);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionBudgetLedger {
    pub id: HypothesisRecursionBudgetLedgerId,
    pub plan_id: HypothesisRecursionPlanId,
    pub node_id: HypothesisRecursionNodeId,
    pub chain: HypothesisRecursionChainLink,
    pub stage: HypothesisRecursionStage,
    pub entry_kind: HypothesisRecursionBudgetEntryKind,
    pub amount_micros_krw: u64,
    pub prior_reserved_micros_krw: u64,
    pub next_reserved_micros_krw: u64,
    pub prior_settled_micros_krw: u64,
    pub next_settled_micros_krw: u64,
    pub receipt_digest: HypothesisRecursionDigest,
}

impl HypothesisRecursionBudgetLedger {
    pub fn validate(mut self) -> Result<Self, DomainError> {
        self.chain = self.chain.validate()?;
        let expected = match self.entry_kind {
            HypothesisRecursionBudgetEntryKind::Reserve => self
                .prior_reserved_micros_krw
                .checked_add(self.amount_micros_krw)
                .map(|reserved| (reserved, self.prior_settled_micros_krw)),
            HypothesisRecursionBudgetEntryKind::Settle => self
                .prior_settled_micros_krw
                .checked_add(self.amount_micros_krw)
                .map(|settled| (self.prior_reserved_micros_krw, settled)),
            HypothesisRecursionBudgetEntryKind::Release => self
                .prior_reserved_micros_krw
                .checked_sub(self.amount_micros_krw)
                .map(|reserved| (reserved, self.prior_settled_micros_krw)),
        };
        if expected != Some((self.next_reserved_micros_krw, self.next_settled_micros_krw))
            || self.next_settled_micros_krw > self.next_reserved_micros_krw
        {
            return Err(DomainError::InvalidAmount);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursionProducerFence {
    job_id: JobId,
    lease_token: Uuid,
    fencing_token: i64,
}

impl HypothesisRecursionProducerFence {
    pub fn try_new(
        job_id: JobId,
        lease_token: Uuid,
        fencing_token: i64,
    ) -> Result<Self, DomainError> {
        if job_id.value().is_nil() || lease_token.is_nil() || fencing_token < 1 {
            return Err(DomainError::InvalidIdentifier);
        }
        Ok(Self {
            job_id,
            lease_token,
            fencing_token,
        })
    }

    pub const fn job_id(&self) -> JobId {
        self.job_id
    }

    pub const fn lease_token(&self) -> Uuid {
        self.lease_token
    }

    pub const fn fencing_token(&self) -> i64 {
        self.fencing_token
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HypothesisRecursion {
    trigger_kind: HypothesisRecursionTriggerKind,
    disposition: HypothesisRecursionDisposition,
    receipt_id: HypothesisRecursionReceiptId,
    receipt_digest: HypothesisRecursionDigest,
    started: Option<HypothesisRecursionStarted>,
    replayed: bool,
}

impl HypothesisRecursion {
    pub fn from_owner_result(
        trigger_kind: HypothesisRecursionTriggerKind,
        disposition: HypothesisRecursionDisposition,
        receipt_id: Uuid,
        receipt_digest: impl Into<String>,
        started: Option<HypothesisRecursionStarted>,
        replayed: bool,
    ) -> Result<Self, DomainError> {
        if (disposition == HypothesisRecursionDisposition::Started) != started.is_some() {
            return Err(DomainError::InvalidTransition);
        }
        Ok(Self {
            trigger_kind,
            disposition,
            receipt_id: HypothesisRecursionReceiptId::try_new(receipt_id)?,
            receipt_digest: HypothesisRecursionDigest::try_new(receipt_digest)?,
            started,
            replayed,
        })
    }

    pub const fn trigger_kind(&self) -> HypothesisRecursionTriggerKind {
        self.trigger_kind
    }

    pub const fn disposition(&self) -> HypothesisRecursionDisposition {
        self.disposition
    }

    pub const fn receipt_id(&self) -> HypothesisRecursionReceiptId {
        self.receipt_id
    }

    pub fn receipt_digest(&self) -> &HypothesisRecursionDigest {
        &self.receipt_digest
    }

    pub const fn started(&self) -> Option<&HypothesisRecursionStarted> {
        self.started.as_ref()
    }

    pub const fn replayed(&self) -> bool {
        self.replayed
    }
}

fn valid_candidate(value: &str) -> bool {
    let bytes = value.as_bytes();
    let Some(first) = bytes.first() else {
        return false;
    };
    (1..=128).contains(&bytes.len())
        && (first.is_ascii_lowercase() || first.is_ascii_digit())
        && bytes[1..].iter().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        })
}
