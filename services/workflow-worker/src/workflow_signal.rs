#[derive(Debug)]
struct SignalInvestigationOutcome {
    disposition: String,
    case_id: Option<Uuid>,
    dataset_snapshot_id: Option<Uuid>,
    agent_run_id: Option<Uuid>,
    job_id: Option<Uuid>,
    receipt_id: Option<Uuid>,
    actor_type: String,
    actor_id: String,
    replayed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SignalInvestigationDisposition {
    Started,
    PolicyAbsent,
    PolicyDisabled,
    KillSwitchActive,
    BelowMinSeverity,
    DuplicateSuppressed,
    DailyLimitReached,
    CaseDailyLimitReached,
    BudgetBlocked,
    EvidenceScopeDenied,
    ProviderUnavailable,
}

impl TryFrom<&str> for SignalInvestigationDisposition {
    type Error = Failure;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "STARTED" => Ok(Self::Started),
            "POLICY_ABSENT" => Ok(Self::PolicyAbsent),
            "POLICY_DISABLED" => Ok(Self::PolicyDisabled),
            "KILL_SWITCH_ACTIVE" => Ok(Self::KillSwitchActive),
            "BELOW_MIN_SEVERITY" => Ok(Self::BelowMinSeverity),
            "DUPLICATE_SUPPRESSED" => Ok(Self::DuplicateSuppressed),
            "DAILY_LIMIT_REACHED" => Ok(Self::DailyLimitReached),
            "CASE_DAILY_LIMIT_REACHED" => Ok(Self::CaseDailyLimitReached),
            "BUDGET_BLOCKED" => Ok(Self::BudgetBlocked),
            "EVIDENCE_SCOPE_DENIED" => Ok(Self::EvidenceScopeDenied),
            "PROVIDER_UNAVAILABLE" => Ok(Self::ProviderUnavailable),
            _ => Err(Failure::Terminal(
                "SIGNAL_INVESTIGATION_DISPOSITION_INVALID",
                value.to_owned(),
            )),
        }
    }
}

impl SignalInvestigationOutcome {
    fn into_metrics(self) -> Result<Value, Failure> {
        SignalInvestigationDisposition::try_from(self.disposition.as_str())?;
        if self.actor_type != "SERVICE" || self.actor_id != "workflow-worker" {
            return Err(Failure::Terminal(
                "SIGNAL_INVESTIGATION_ACTOR_INVALID",
                format!("{}/{}", self.actor_type, self.actor_id),
            ));
        }
        Ok(json!({
            "disposition":self.disposition,
            "caseId":self.case_id,
            "datasetSnapshotId":self.dataset_snapshot_id,
            "agentRunId":self.agent_run_id,
            "jobId":self.job_id,
            "receiptId":self.receipt_id,
            "actorType":self.actor_type,
            "actorId":self.actor_id,
            "replayed":self.replayed,
        }))
    }
}

async fn reconcile_signal_created(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
    producer_job_id: Uuid,
) -> Result<Value, Failure> {
    let signal = object_uuid(payload, "signal_id")?;
    let mut tx = pool.begin().await.map_err(database)?;
    let exists = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM core.anomaly_signals WHERE id=$1)",
        signal,
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    let exists = required(exists).map_err(database)?;
    if !exists {
        return Err(Failure::Terminal("SIGNAL_NOT_FOUND", signal.to_string()));
    }
    // A started run is reviewed through the existing agent.run_completed -> AGENT_REVIEW path.
    // Keeping SIGNAL_TRIAGE unchanged preserves the human signal queue without granting this
    // automation any suggestion-acceptance, case-transition, or publication authority.
    let investigation = sqlx::query_as!(
        SignalInvestigationOutcome,
        r#"SELECT
             disposition AS "disposition!",case_id,dataset_snapshot_id,agent_run_id,job_id,
             receipt_id,actor_type AS "actor_type!",actor_id AS "actor_id!",
             replayed AS "replayed!"
           FROM ops.process_signal_investigation_v1($1,$2)"#,
        signal,
        producer_job_id,
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    let task_created = signal_task_created(sqlx::query!(
        "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority) \
         SELECT 'SIGNAL_TRIAGE','SIGNAL',$1,'Triage detected signal','OPEN', \
           CASE severity WHEN 'CRITICAL' THEN 'URGENT' WHEN 'HIGH' THEN 'HIGH' ELSE 'NORMAL' END \
         FROM core.anomaly_signals WHERE id=$1 AND NOT EXISTS( \
           SELECT 1 FROM ops.tasks WHERE task_type='SIGNAL_TRIAGE' AND object_id=$1 AND status<>'DONE')",
        signal,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected());
    tx.commit().await.map_err(database)?;
    signal_reconciliation_metrics(signal, task_created, investigation)
}

fn signal_reconciliation_metrics(
    signal_id: Uuid,
    task_created: bool,
    investigation: SignalInvestigationOutcome,
) -> Result<Value, Failure> {
    Ok(json!({
        "signalId":signal_id,
        "taskCreated":task_created,
        "automaticInvestigation":investigation.into_metrics()?,
    }))
}

fn signal_task_created(rows_affected: u64) -> bool {
    rows_affected > 0
}

#[cfg(test)]
mod signal_tests {
    use uuid::Uuid;

    use super::{
        Failure, SignalInvestigationOutcome, signal_reconciliation_metrics, signal_task_created,
    };

    fn outcome(disposition: &str) -> SignalInvestigationOutcome {
        SignalInvestigationOutcome {
            disposition: disposition.to_owned(),
            case_id: None,
            dataset_snapshot_id: None,
            agent_run_id: None,
            job_id: None,
            receipt_id: None,
            actor_type: "SERVICE".to_owned(),
            actor_id: "workflow-worker".to_owned(),
            replayed: false,
        }
    }

    #[test]
    fn signal_task_result_reports_insert_and_deduplication_honestly() {
        assert!(signal_task_created(1));
        assert!(!signal_task_created(0));
        let signal_id = Uuid::from_u128(10);
        let inserted = signal_reconciliation_metrics(signal_id, true, outcome("POLICY_ABSENT"))
            .expect("inserted task metrics");
        let deduplicated =
            signal_reconciliation_metrics(signal_id, false, outcome("POLICY_ABSENT"))
                .expect("deduplicated task metrics");
        assert_eq!(inserted.get("taskCreated").and_then(serde_json::Value::as_bool), Some(true));
        assert_eq!(
            deduplicated
                .get("taskCreated")
                .and_then(serde_json::Value::as_bool),
            Some(false)
        );
    }

    #[test]
    fn absent_and_disabled_policy_are_successful_no_op_metrics() {
        for disposition in ["POLICY_ABSENT", "POLICY_DISABLED"] {
            let metrics = outcome(disposition)
                .into_metrics()
                .expect("policy no-op is a successful reconciliation result");
            assert_eq!(
                metrics.get("disposition").and_then(serde_json::Value::as_str),
                Some(disposition),
            );
            assert_eq!(
                metrics.get("actorType").and_then(serde_json::Value::as_str),
                Some("SERVICE"),
            );
            assert_eq!(
                metrics.get("actorId").and_then(serde_json::Value::as_str),
                Some("workflow-worker"),
            );
        }
    }

    #[test]
    fn persisted_investigation_dispositions_form_a_closed_success_set() {
        for disposition in [
            "STARTED",
            "POLICY_ABSENT",
            "POLICY_DISABLED",
            "KILL_SWITCH_ACTIVE",
            "BELOW_MIN_SEVERITY",
            "DUPLICATE_SUPPRESSED",
            "DAILY_LIMIT_REACHED",
            "CASE_DAILY_LIMIT_REACHED",
            "BUDGET_BLOCKED",
            "EVIDENCE_SCOPE_DENIED",
            "PROVIDER_UNAVAILABLE",
        ] {
            assert!(outcome(disposition).into_metrics().is_ok(), "{disposition}");
        }
        assert!(matches!(
            outcome("UNDECLARED").into_metrics(),
            Err(Failure::Terminal(
                "SIGNAL_INVESTIGATION_DISPOSITION_INVALID",
                _
            ))
        ));
    }

    #[test]
    fn investigation_metrics_reject_non_service_actor_results() {
        let mut invalid_type = outcome("POLICY_DISABLED");
        invalid_type.actor_type = "HUMAN".to_owned();
        let mut invalid_id = outcome("POLICY_DISABLED");
        invalid_id.actor_id = Uuid::from_u128(1).to_string();
        for invalid in [invalid_type, invalid_id] {
            assert!(matches!(
                invalid.into_metrics(),
                Err(Failure::Terminal(
                    "SIGNAL_INVESTIGATION_ACTOR_INVALID",
                    _
                ))
            ));
        }
    }

    #[test]
    fn replayed_started_outcome_preserves_owner_procedure_ids() {
        let mut replay = outcome("STARTED");
        let case_id = Uuid::from_u128(1);
        let snapshot_id = Uuid::from_u128(2);
        let agent_run_id = Uuid::from_u128(3);
        let job_id = Uuid::from_u128(4);
        let receipt_id = Uuid::from_u128(5);
        replay.case_id = Some(case_id);
        replay.dataset_snapshot_id = Some(snapshot_id);
        replay.agent_run_id = Some(agent_run_id);
        replay.job_id = Some(job_id);
        replay.receipt_id = Some(receipt_id);
        replay.replayed = true;

        let metrics = replay.into_metrics().expect("replay is a successful result");
        assert_eq!(metrics.get("caseId"), Some(&serde_json::json!(case_id)));
        assert_eq!(
            metrics.get("datasetSnapshotId"),
            Some(&serde_json::json!(snapshot_id))
        );
        assert_eq!(
            metrics.get("agentRunId"),
            Some(&serde_json::json!(agent_run_id))
        );
        assert_eq!(metrics.get("jobId"), Some(&serde_json::json!(job_id)));
        assert_eq!(
            metrics.get("receiptId"),
            Some(&serde_json::json!(receipt_id))
        );
        assert_eq!(metrics.get("replayed").and_then(serde_json::Value::as_bool), Some(true));
    }
}
