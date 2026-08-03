use gurine_domain::{
    hypothesis_recursion::{
        HypothesisExecutionId, HypothesisRecursion, HypothesisRecursionBudgetEntryKind,
        HypothesisRecursionBudgetLedger, HypothesisRecursionBudgetLedgerId,
        HypothesisRecursionChainLink, HypothesisRecursionDigest, HypothesisRecursionDisposition,
        HypothesisRecursionNode, HypothesisRecursionNodeId, HypothesisRecursionPlan,
        HypothesisRecursionPlanId, HypothesisRecursionPolicyId, HypothesisRecursionPolicyLimits,
        HypothesisRecursionProducerFence, HypothesisRecursionProviderClassification,
        HypothesisRecursionProviderPolicy, HypothesisRecursionSnapshotId, HypothesisRecursionStage,
        HypothesisRecursionTriggerKind,
    },
    ids::{CaseId, JobId},
};
use uuid::Uuid;

const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn digest() -> HypothesisRecursionDigest {
    HypothesisRecursionDigest::try_new(DIGEST).expect("valid test digest")
}

fn plan(max_depth: u8) -> HypothesisRecursionPlan {
    HypothesisRecursionPlan {
        id: HypothesisRecursionPlanId::try_new(Uuid::from_u128(10)).expect("plan id"),
        case_id: CaseId::new(Uuid::from_u128(11)),
        root_execution_id: HypothesisExecutionId::try_new(Uuid::from_u128(12))
            .expect("execution id"),
        root_execution_generation: 1,
        root_execution_digest: digest(),
        snapshot_id: HypothesisRecursionSnapshotId::try_new(Uuid::from_u128(13))
            .expect("snapshot id"),
        snapshot_digest: digest(),
        policy_id: HypothesisRecursionPolicyId::try_new(Uuid::from_u128(14)).expect("policy id"),
        policy_version: 1,
        policy_digest: digest(),
        max_depth,
        case_budget_micros_krw: 3,
        digest: digest(),
    }
}

#[test]
fn owner_result_enforces_closed_dispositions_and_shape() {
    for value in [
        "POLICY_ABSENT",
        "POLICY_DISABLED",
        "MAX_DEPTH_REACHED",
        "CASE_BUDGET_BLOCKED",
        "NOT_HYPOTHESIS",
        "NOT_SUCCEEDED",
        "NODE_NOT_RECURSIVE",
        "STAGE_NOT_MARKET_RESEARCHER",
        "RUN_NOT_SUCCEEDED",
        "PLAN_TERMINAL",
    ] {
        let disposition =
            HypothesisRecursionDisposition::try_from(value).expect("closed disposition");
        assert!(
            HypothesisRecursion::from_owner_result(
                HypothesisRecursionTriggerKind::AgentRun,
                disposition,
                Uuid::from_u128(5),
                DIGEST,
                None,
                false,
            )
            .is_ok()
        );
    }
    assert!(HypothesisRecursionDisposition::try_from("CLAIM_DRAFTER_STARTED").is_err());
    assert!(
        HypothesisRecursion::from_owner_result(
            HypothesisRecursionTriggerKind::ActionExecution,
            HypothesisRecursionDisposition::Started,
            Uuid::from_u128(5),
            DIGEST,
            None,
            false,
        )
        .is_err()
    );
}

#[test]
fn node_parent_and_budget_ledger_invariants_are_closed() {
    let node = HypothesisRecursionNode {
        id: HypothesisRecursionNodeId::try_new(Uuid::from_u128(1)).expect("node id"),
        plan_id: gurine_domain::hypothesis_recursion::HypothesisRecursionPlanId::try_new(
            Uuid::from_u128(2),
        )
        .expect("plan id"),
        parent: None,
        case_id: CaseId::new(Uuid::from_u128(3)),
        depth: 1,
        stage: HypothesisRecursionStage::MarketResearcher,
        execution_digest: digest(),
        snapshot_id: gurine_domain::hypothesis_recursion::HypothesisRecursionSnapshotId::try_new(
            Uuid::from_u128(4),
        )
        .expect("snapshot id"),
        snapshot_digest: digest(),
        agent_run_id: gurine_domain::hypothesis_recursion::HypothesisRecursionAgentRunId::try_new(
            Uuid::from_u128(5),
        )
        .expect("run id"),
        job_id: JobId::new(Uuid::from_u128(6)),
        reserved_micros_krw: 10,
        dedupe_digest: digest(),
        digest: digest(),
    };
    assert!(node.clone().validate().is_ok());
    let root_id = node.id;
    let mut child = node.clone();
    child.id = HypothesisRecursionNodeId::try_new(Uuid::from_u128(8)).expect("child node id");
    child.depth = 2;
    child.parent = Some((root_id, 1));
    child.stage = HypothesisRecursionStage::Skeptic;
    assert!(child.clone().validate().is_ok());
    child.parent = Some((root_id, 2));
    assert!(child.clone().validate().is_err());
    child.depth = 17;
    child.parent = Some((root_id, 16));
    assert!(child.validate().is_err());

    let ledger = HypothesisRecursionBudgetLedger {
        id: HypothesisRecursionBudgetLedgerId::try_new(Uuid::from_u128(7)).expect("ledger id"),
        plan_id: gurine_domain::hypothesis_recursion::HypothesisRecursionPlanId::try_new(
            Uuid::from_u128(2),
        )
        .expect("plan id"),
        node_id: HypothesisRecursionNodeId::try_new(Uuid::from_u128(1)).expect("node id"),
        chain: HypothesisRecursionChainLink {
            sequence: 1,
            prior: None,
        },
        stage: HypothesisRecursionStage::MarketResearcher,
        entry_kind: HypothesisRecursionBudgetEntryKind::Reserve,
        amount_micros_krw: 10,
        prior_reserved_micros_krw: 0,
        next_reserved_micros_krw: 10,
        prior_settled_micros_krw: 0,
        next_settled_micros_krw: 0,
        receipt_digest: digest(),
    };
    assert!(ledger.validate().is_ok());
}

#[test]
fn max_depth_counts_child_nodes_and_is_bounded_at_sixteen() {
    let mut limits = HypothesisRecursionPolicyLimits {
        max_depth: 1,
        case_budget_micros_krw: 3,
        market_researcher_stage_budget_micros_krw: 2,
        skeptic_stage_budget_micros_krw: 1,
        max_provider_turns: 1,
        max_tool_calls: 0,
        deadline: time::Duration::seconds(1),
    };
    assert!(limits.clone().validate().is_ok());
    limits.max_depth = 0;
    assert!(limits.clone().validate().is_err());
    limits.max_depth = 16;
    assert!(limits.clone().validate().is_ok());
    limits.max_depth = 17;
    assert!(limits.validate().is_err());
    assert!(plan(0).validate().is_err());
    assert!(plan(1).validate().is_ok());
    assert!(plan(16).validate().is_ok());
    assert!(plan(17).validate().is_err());
}

#[test]
fn producer_fence_and_policy_candidates_fail_closed() {
    assert!(
        HypothesisRecursionProducerFence::try_new(
            JobId::new(Uuid::from_u128(1)),
            Uuid::from_u128(2),
            1,
        )
        .is_ok()
    );
    assert!(
        HypothesisRecursionProducerFence::try_new(JobId::new(Uuid::from_u128(1)), Uuid::nil(), 1,)
            .is_err()
    );
    assert!(
        HypothesisRecursionProviderPolicy::try_new(
            "v1",
            digest(),
            HypothesisRecursionProviderClassification::Internal,
            vec!["relay".to_owned(), "relay".to_owned()],
        )
        .is_err()
    );
}
