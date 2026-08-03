use gurine_domain::{
    hypothesis_recursion::{HypothesisRecursion, HypothesisRecursionProducerFence},
    ids::JobId,
};
use gurine_persistence_postgres::hypothesis_recursion::{
    HypothesisRecursionRepository, HypothesisRecursionRepositoryError,
};

fn hypothesis_recursion_metrics(outcome: &HypothesisRecursion) -> Value {
    let started = outcome.started();
    json!({
        "triggerKind":outcome.trigger_kind().as_str(),
        "disposition":outcome.disposition().as_str(),
        "receiptId":outcome.receipt_id().value(),
        "receiptDigest":outcome.receipt_digest().as_str(),
        "planId":started.map(|value| value.plan_id.value()),
        "nodeId":started.map(|value| value.node_id.value()),
        "agentRunId":started.map(|value| value.agent_run_id.value()),
        "jobId":started.map(|value| value.job_id.value()),
        "replayed":outcome.replayed(),
    })
}

fn hypothesis_recursion_fence(
    producer_job_id: Uuid,
    producer_job_lease_token: Uuid,
    producer_job_fencing_token: i64,
) -> Result<HypothesisRecursionProducerFence, Failure> {
    HypothesisRecursionProducerFence::try_new(
        JobId::new(producer_job_id),
        producer_job_lease_token,
        producer_job_fencing_token,
    )
    .map_err(|_| {
        Failure::Terminal(
            "HYPOTHESIS_RECURSION_PRODUCER_FENCE_INVALID",
            "producer job fence violated the closed recursion contract".to_owned(),
        )
    })
}

fn hypothesis_recursion_repository_failure(error: HypothesisRecursionRepositoryError) -> Failure {
    match error {
        HypothesisRecursionRepositoryError::Database(error) => database(error),
        HypothesisRecursionRepositoryError::Contract(_) => Failure::Terminal(
            "HYPOTHESIS_RECURSION_OWNER_CONTRACT_INVALID",
            "owner result violated the closed recursion contract".to_owned(),
        ),
    }
}

async fn reconcile_hypothesis_execution_completed(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
    producer_job_id: Uuid,
    producer_job_lease_token: Uuid,
    producer_job_fencing_token: i64,
) -> Result<Value, Failure> {
    let fence = hypothesis_recursion_fence(
        producer_job_id,
        producer_job_lease_token,
        producer_job_fencing_token,
    )?;
    let outcome = HypothesisRecursionRepository::new(pool.clone())
        .process_hypothesis_execution_completed(payload, &fence)
        .await
        .map_err(hypothesis_recursion_repository_failure)?;
    Ok(hypothesis_recursion_metrics(&outcome))
}

async fn reconcile_hypothesis_recursion_stage_completed(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
    producer_job_id: Uuid,
    producer_job_lease_token: Uuid,
    producer_job_fencing_token: i64,
) -> Result<Value, Failure> {
    let fence = hypothesis_recursion_fence(
        producer_job_id,
        producer_job_lease_token,
        producer_job_fencing_token,
    )?;
    let outcome = HypothesisRecursionRepository::new(pool.clone())
        .process_recursion_stage_completed(payload, &fence)
        .await
        .map_err(hypothesis_recursion_repository_failure)?;
    Ok(hypothesis_recursion_metrics(&outcome))
}

#[cfg(test)]
mod hypothesis_recursion_tests {
    use std::collections::BTreeSet;

    use gurine_domain::hypothesis_recursion::{
        HypothesisRecursion, HypothesisRecursionDisposition, HypothesisRecursionStarted,
        HypothesisRecursionTriggerKind,
    };
    use serde_json::Value;
    use uuid::Uuid;

    use super::hypothesis_recursion_metrics;

    const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn outcome(
        disposition: HypothesisRecursionDisposition,
        started: Option<HypothesisRecursionStarted>,
        replayed: bool,
    ) -> HypothesisRecursion {
        HypothesisRecursion::from_owner_result(
            HypothesisRecursionTriggerKind::ActionExecution,
            disposition,
            Uuid::from_u128(1),
            DIGEST,
            started,
            replayed,
        )
        .expect("valid closed owner result")
    }

    fn started() -> HypothesisRecursionStarted {
        HypothesisRecursionStarted::try_new(
            Uuid::from_u128(2),
            Uuid::from_u128(3),
            Uuid::from_u128(4),
            Uuid::from_u128(5),
        )
        .expect("valid started identities")
    }

    #[test]
    fn started_and_exact_replay_preserve_every_created_identity() {
        let started_metrics = hypothesis_recursion_metrics(&outcome(
            HypothesisRecursionDisposition::Started,
            Some(started()),
            false,
        ));
        let replayed_metrics = hypothesis_recursion_metrics(&outcome(
            HypothesisRecursionDisposition::Started,
            Some(started()),
            true,
        ));
        assert_eq!(
            started_metrics.as_object().map(|value| {
                value.keys().map(String::as_str).collect::<BTreeSet<_>>()
            }),
            Some(BTreeSet::from([
                "agentRunId",
                "disposition",
                "jobId",
                "nodeId",
                "planId",
                "receiptDigest",
                "receiptId",
                "replayed",
                "triggerKind",
            ]))
        );
        assert_eq!(
            started_metrics.get("triggerKind").and_then(Value::as_str),
            Some("ACTION_EXECUTION")
        );
        assert_eq!(
            started_metrics.get("disposition").and_then(Value::as_str),
            Some("STARTED")
        );
        for field in [
            "receiptId",
            "receiptDigest",
            "planId",
            "nodeId",
            "agentRunId",
            "jobId",
        ] {
            assert_eq!(started_metrics.get(field), replayed_metrics.get(field));
        }
        assert_eq!(started_metrics.get("replayed"), Some(&Value::Bool(false)));
        assert_eq!(replayed_metrics.get("replayed"), Some(&Value::Bool(true)));
    }

    #[test]
    fn durable_no_op_dispositions_keep_created_identities_null() {
        for disposition in [
            HypothesisRecursionDisposition::PolicyAbsent,
            HypothesisRecursionDisposition::PolicyDisabled,
            HypothesisRecursionDisposition::MaxDepthReached,
            HypothesisRecursionDisposition::CaseBudgetBlocked,
            HypothesisRecursionDisposition::NotHypothesis,
            HypothesisRecursionDisposition::NotSucceeded,
            HypothesisRecursionDisposition::NodeNotRecursive,
            HypothesisRecursionDisposition::StageNotMarketResearcher,
            HypothesisRecursionDisposition::RunNotSucceeded,
            HypothesisRecursionDisposition::PlanTerminal,
        ] {
            let metrics = hypothesis_recursion_metrics(&outcome(disposition, None, false));
            for field in ["planId", "nodeId", "agentRunId", "jobId"] {
                assert_eq!(metrics.get(field), Some(&Value::Null));
            }
        }
    }

    #[test]
    fn aggregate_rejects_wrong_shape_unknown_disposition_and_bad_receipt() {
        assert!(
            HypothesisRecursion::from_owner_result(
                HypothesisRecursionTriggerKind::AgentRun,
                HypothesisRecursionDisposition::Started,
                Uuid::from_u128(1),
                DIGEST,
                None,
                false,
            )
            .is_err()
        );
        assert!(HypothesisRecursionDisposition::try_from("CLAIM_DRAFTER_STARTED").is_err());
        assert!(
            HypothesisRecursion::from_owner_result(
                HypothesisRecursionTriggerKind::AgentRun,
                HypothesisRecursionDisposition::PolicyDisabled,
                Uuid::nil(),
                "A".repeat(64),
                None,
                false,
            )
            .is_err()
        );
    }
}
