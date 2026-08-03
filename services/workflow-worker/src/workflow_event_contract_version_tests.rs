use super::{
    AgentRunContractVersion, AgentRunReconciliationPath, Failure, agent_run_metrics,
    agent_run_reconciliation_path,
};
use uuid::Uuid;

#[test]
fn only_v2_requires_the_recursion_owner() {
    assert!(matches!(
        AgentRunContractVersion::try_from(1),
        Ok(AgentRunContractVersion::V1)
    ));
    assert!(matches!(
        AgentRunContractVersion::try_from(2),
        Ok(AgentRunContractVersion::V2)
    ));
    for invalid in [0, 3] {
        let error = AgentRunContractVersion::try_from(invalid)
            .expect_err("unknown agent-run contract version must fail closed");
        assert!(matches!(error, Failure::Terminal(_, _)));
    }
}

#[test]
fn v1_preserves_legacy_non_success_and_metrics_contract() {
    for status in ["FAILED", "CANCELLED", "BUDGET_BLOCKED"] {
        let error = agent_run_reconciliation_path(AgentRunContractVersion::V1, status, None)
            .expect_err("legacy non-success must remain terminal");
        assert!(matches!(
            error,
            Failure::Terminal("AGENT_RUN_NOT_SUCCEEDED", _)
        ));
    }
    let Ok(path) =
        agent_run_reconciliation_path(AgentRunContractVersion::V1, "SUCCEEDED", Some("FAILED"))
    else {
        return;
    };
    let metrics = agent_run_metrics(path, Uuid::from_u128(1), "SUCCEEDED", 2);
    assert_eq!(metrics.as_object().map(|object| object.len()), Some(2));
    assert!(metrics.get("status").is_none());
}

#[test]
fn v2_requires_exact_event_status_and_forwards_terminal_states() {
    assert!(
        agent_run_reconciliation_path(AgentRunContractVersion::V2, "SUCCEEDED", None).is_err()
    );
    assert!(
        agent_run_reconciliation_path(AgentRunContractVersion::V2, "SUCCEEDED", Some("FAILED"))
            .is_err()
    );
    assert!(matches!(
        agent_run_reconciliation_path(AgentRunContractVersion::V2, "FAILED", Some("FAILED"))
            ,
        Ok(AgentRunReconciliationPath::V2Terminal)
    ));
}
