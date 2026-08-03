async fn handle_event(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    field_keys: &EnvelopeKeyRing,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    if job.job_type != "EVENT_DELIVERY" {
        return Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            job.job_type.clone(),
        ));
    }
    let event_type = job
        .payload
        .get("eventType")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "eventType is missing".to_owned()))?;
    let event_id = value_uuid(&job.payload, "eventId")?;
    let consumer_id = job
        .payload
        .get("consumerId")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "consumerId is missing".to_owned()))?;
    let aggregate_id = value_uuid(&job.payload, "aggregateId")?;
    let payload = job
        .payload
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "payload is missing".to_owned()))?;
    if workflow_inbox_processed(pool, consumer_id, event_id).await? {
        return Ok(json!({"deduplicated":true,"eventId":event_id}));
    }
    let metrics = reconcile_event(
        pool,
        store,
        scanner,
        field_keys,
        job.id,
        job.fence.lease_token,
        job.fence.fencing_token,
        event_type,
        consumer_id,
        aggregate_id,
        payload,
    )
    .await?;
    mark_workflow_inbox_processed(pool, consumer_id, event_id).await?;
    tracing::info!(%event_id,event_type,"workflow event reconciled");
    Ok(metrics)
}

async fn workflow_inbox_processed(
    pool: &PgPool,
    consumer_id: &str,
    event_id: Uuid,
) -> Result<bool, Failure> {
    sqlx::query_scalar!(
        "SELECT processed_at IS NOT NULL FROM ops.inbox \
         WHERE consumer=$1 AND event_id=$2",
        consumer_id,
        event_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .map(required)
    .transpose()
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_MISSING", event_id.to_string()))
}

async fn reconcile_event(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    field_keys: &EnvelopeKeyRing,
    producer_job_id: Uuid,
    producer_job_lease_token: Uuid,
    producer_job_fencing_token: i64,
    event_type: &str,
    consumer_id: &str,
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let metrics = if consumer_id == "action-execution-worker" {
        if event_type != "action.execution_authorized.v1" {
            return Err(Failure::Terminal(
                "CONSUMER_BINDING_INVALID",
                format!("{consumer_id}:{event_type}"),
            ));
        }
        execute_approved_action(
            pool,
            field_keys,
            producer_job_id,
            producer_job_lease_token,
            producer_job_fencing_token,
            aggregate_id,
            payload,
        )
        .await?
    } else if matches!(
        consumer_id,
        "response-request-materializer" | "response-clock-worker"
    ) {
        reconcile_communication_delivery_receipt(pool, consumer_id, payload).await?
    } else if consumer_id != "workflow-worker" {
        return Err(Failure::Terminal(
            "CONSUMER_BINDING_INVALID",
            consumer_id.to_owned(),
        ));
    } else {
        match event_type {
            "action.execution_completed.v1" => {
                reconcile_hypothesis_execution_completed(
                    pool,
                    payload,
                    producer_job_id,
                    producer_job_lease_token,
                    producer_job_fencing_token,
                )
                .await?
            }
            "agent.run_completed.v1" => {
                let agent_run = reconcile_agent_run(pool, payload).await?;
                match agent_run.contract_version {
                    AgentRunContractVersion::V1 => agent_run.metrics,
                    AgentRunContractVersion::V2 => {
                        let recursion = reconcile_hypothesis_recursion_stage_completed(
                            pool,
                            payload,
                            producer_job_id,
                            producer_job_lease_token,
                            producer_job_fencing_token,
                        )
                        .await?;
                        json!({"agentRun":agent_run.metrics,"hypothesisRecursion":recursion})
                    }
                }
            }
            "attachment.correction_scan_requested.v1" => {
                scan_attachment(pool, store, scanner, "CORRECTION", aggregate_id).await?
            }
            "attachment.response_scan_requested.v1" => {
                scan_attachment(pool, store, scanner, "RESPONSE", aggregate_id).await?
            }
            "audit.export_requested.v1" => export_audit(pool, store, aggregate_id).await?,
            "detection.signal_created.v1" => {
                reconcile_signal_created(pool, payload, producer_job_id).await?
            }
            "export.dataset_requested.v1" => export_dataset(pool, store, aggregate_id).await?,
            "source.schema_drift_detected.v1" => reconcile_schema_drift(pool, payload).await?,
            "workflow.response_submitted.v1" => reconcile_response(pool, aggregate_id).await?,
            _ => {
                return Err(Failure::Terminal(
                    "UNSUPPORTED_EVENT_TYPE",
                    event_type.to_owned(),
                ));
            }
        }
    };
    Ok(metrics)
}

async fn mark_workflow_inbox_processed(
    pool: &PgPool,
    consumer_id: &str,
    event_id: Uuid,
) -> Result<(), Failure> {
    let changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
        consumer_id,
        event_id,
    )
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "INBOX_FENCE_FAILED",
            event_id.to_string(),
        ));
    }
    Ok(())
}

async fn reconcile_communication_delivery_receipt(
    pool: &PgPool,
    consumer_id: &str,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let receipt_id = object_uuid(payload, "deliveryReceiptId")?;
    let delivery_id = object_uuid(payload, "deliveryId")?;
    let sequence = payload
        .get("deliveryReceiptSequence")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("INVALID_DELIVERY_RECEIPT", "sequence".to_owned()))?;
    let digest = payload
        .get("receiptDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or_else(|| Failure::Terminal("INVALID_DELIVERY_RECEIPT", "digest".to_owned()))?;
    let state = payload
        .get("state")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_DELIVERY_RECEIPT", "state".to_owned()))?;
    let applied = payload
        .get("receiptApplied")
        .and_then(Value::as_bool)
        .ok_or_else(|| Failure::Terminal("INVALID_DELIVERY_RECEIPT", "applied".to_owned()))?;
    let exact = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM ops.outbound_delivery_receipts \
         WHERE id=$1 AND delivery_id=$2 AND receipt_sequence=$3 \
           AND receipt_digest=$4 AND resulting_state=$5 AND applied=$6)",
        receipt_id,
        delivery_id,
        sequence,
        digest,
        state,
        applied,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    let exact = required(exact).map_err(database)?;
    if !exact {
        return Err(Failure::Terminal(
            "DELIVERY_RECEIPT_MISMATCH",
            receipt_id.to_string(),
        ));
    }
    Ok(json!({
        "consumerId":consumer_id,
        "deliveryId":delivery_id,
        "deliveryReceiptId":receipt_id,
        "receiptApplied":applied,
        "state":state,
    }))
}

struct AttachmentScanRow {
    object_key: String,
    size_bytes: i64,
    sha256: Option<String>,
}

async fn scan_attachment(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    kind: &str,
    id: Uuid,
) -> Result<Value, Failure> {
    let row = match kind {
        "RESPONSE" => sqlx::query_as!(
            AttachmentScanRow,
            "SELECT object_key,size_bytes,sha256::text AS \"sha256?\" \
             FROM intake.response_attachments \
             WHERE id=$1 AND upload_status='FINALIZED' AND scan_status='PENDING'",
            id,
        )
        .fetch_optional(pool)
        .await
        .map_err(database)?,
        "CORRECTION" => sqlx::query_as!(
            AttachmentScanRow,
            "SELECT object_key,size_bytes,sha256::text AS \"sha256?\" \
             FROM intake.correction_draft_attachments \
             WHERE id=$1 AND upload_status='FINALIZED' AND scan_status='PENDING'",
            id,
        )
        .fetch_optional(pool)
        .await
        .map_err(database)?,
        _ => {
            return Err(Failure::Terminal(
                "ATTACHMENT_KIND_INVALID",
                kind.to_owned(),
            ));
        }
    }
    .ok_or_else(|| Failure::Terminal("ATTACHMENT_NOT_PENDING", id.to_string()))?;
    let key = row.object_key;
    let expected_size = row.size_bytes;
    let expected_sha256 = required(row.sha256).map_err(database)?;
    let bytes = get(store, &key, expected_sha256.trim())
        .await
        .map_err(|error| match error {
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                Failure::Terminal("ATTACHMENT_OBJECT_INVALID", id.to_string())
            }
            ObjectStoreError::Backend(error) => {
                Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
            }
        })?;
    if i64::try_from(bytes.len()).ok() != Some(expected_size) {
        return Err(Failure::Terminal(
            "ATTACHMENT_SIZE_MISMATCH",
            id.to_string(),
        ));
    }
    let status = match scanner.scan(&bytes).await {
        Ok(ScanResult::Clean) => "CLEAN",
        Ok(ScanResult::Infected) => "INFECTED",
        Err(error) => return Err(Failure::Retryable("SCANNER_UNAVAILABLE", error.to_string())),
    };
    let event_id = sqlx::query_scalar!(
        "SELECT ops.enqueue_outbox('attachment',$1,1,'attachment.scan_completed.v1',$2,clock_timestamp())",
        id.to_string(),
        json!({"attachment_id":id,"attachment_kind":kind,"scan_status":status,
            "sha256":expected_sha256.trim()}),
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    let event_id = required(event_id).map_err(database)?;
    tracing::info!(attachment_id=%id, attachment_kind=%kind, scan_status=status, %event_id, "attachment scan completed");
    Ok(json!({"attachmentId":id,"attachmentKind":kind,"scanStatus":status,"eventId":event_id}))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AgentRunContractVersion {
    V1,
    V2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AgentRunReconciliationPath {
    LegacySucceeded,
    V2Succeeded,
    V2Terminal,
}

fn agent_run_reconciliation_path(
    contract_version: AgentRunContractVersion,
    persisted_status: &str,
    event_status: Option<&str>,
) -> Result<AgentRunReconciliationPath, Failure> {
    match contract_version {
        AgentRunContractVersion::V1 if persisted_status == "SUCCEEDED" => {
            Ok(AgentRunReconciliationPath::LegacySucceeded)
        }
        AgentRunContractVersion::V1 => Err(Failure::Terminal(
            "AGENT_RUN_NOT_SUCCEEDED",
            persisted_status.to_owned(),
        )),
        AgentRunContractVersion::V2 => {
            let event_status = event_status
                .ok_or_else(|| Failure::Terminal("INVALID_AGENT_EVENT", "status".to_owned()))?;
            if event_status != persisted_status {
                return Err(Failure::Terminal(
                    "AGENT_RUN_STATUS_MISMATCH",
                    format!("{event_status}:{persisted_status}"),
                ));
            }
            if persisted_status == "SUCCEEDED" {
                Ok(AgentRunReconciliationPath::V2Succeeded)
            } else {
                Ok(AgentRunReconciliationPath::V2Terminal)
            }
        }
    }
}

fn agent_run_metrics(
    path: AgentRunReconciliationPath,
    run_id: Uuid,
    status: &str,
    suggestions: i64,
) -> Value {
    match path {
        AgentRunReconciliationPath::LegacySucceeded => {
            json!({"agentRunId":run_id,"suggestions":suggestions})
        }
        AgentRunReconciliationPath::V2Succeeded => {
            json!({"agentRunId":run_id,"status":status,"suggestions":suggestions})
        }
        AgentRunReconciliationPath::V2Terminal => {
            json!({"agentRunId":run_id,"status":status,"suggestions":0})
        }
    }
}

impl TryFrom<i16> for AgentRunContractVersion {
    type Error = Failure;

    fn try_from(value: i16) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::V1),
            2 => Ok(Self::V2),
            _ => Err(Failure::Terminal(
                "AGENT_RUN_CONTRACT_VERSION_INVALID",
                value.to_string(),
            )),
        }
    }
}

struct ReconciledAgentRun {
    contract_version: AgentRunContractVersion,
    metrics: Value,
}

async fn reconcile_agent_run(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
) -> Result<ReconciledAgentRun, Failure> {
    let run_id = object_uuid(payload, "agent_run_id")?;
    let case_id = object_uuid(payload, "case_id")?;
    let expected = payload
        .get("output_digest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or_else(|| Failure::Terminal("INVALID_AGENT_EVENT", "output digest".to_owned()))?;
    let event_status = payload.get("status").and_then(Value::as_str);
    let row = sqlx::query!(
        "SELECT status,output_payload,run_contract_version AS \"run_contract_version!\" \
         FROM ops.agent_runs WHERE id=$1 AND case_id=$2",
        run_id,
        case_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_FOUND", run_id.to_string()))?;
    let contract_version = AgentRunContractVersion::try_from(row.run_contract_version)?;
    let status = row.status;
    let output = row.output_payload;
    let path = agent_run_reconciliation_path(contract_version, &status, event_status)?;
    if path == AgentRunReconciliationPath::V2Terminal {
        return Ok(ReconciledAgentRun {
            contract_version,
            metrics: agent_run_metrics(path, run_id, &status, 0),
        });
    }
    let output = output.ok_or_else(|| {
        Failure::Terminal("AGENT_OUTPUT_MISSING", "output payload is null".to_owned())
    })?;
    if sha256(
        &serde_json::to_vec(&output)
            .map_err(|error| Failure::Terminal("AGENT_OUTPUT_INVALID", error.to_string()))?,
    ) != expected
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_DIGEST_MISMATCH",
            run_id.to_string(),
        ));
    }
    let suggestions = sqlx::query_scalar!(
        "SELECT count(*) FROM ops.agent_suggestions WHERE agent_run_id=$1 AND status='PENDING'",
        run_id,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    let suggestions = required(suggestions).map_err(database)?;
    if suggestions > 0 {
        sqlx::query!(
            "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority) \
             VALUES('AGENT_REVIEW','AGENT_RUN',$1,'Review agent suggestions','OPEN','NORMAL') \
             ON CONFLICT DO NOTHING",
            run_id,
        )
        .execute(pool)
        .await
        .map_err(database)?;
    }
    Ok(ReconciledAgentRun {
        contract_version,
        metrics: agent_run_metrics(path, run_id, &status, suggestions),
    })
}

#[cfg(test)]
mod agent_run_contract_version_tests {
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
        let path =
            agent_run_reconciliation_path(AgentRunContractVersion::V1, "SUCCEEDED", Some("FAILED"))
                .expect("legacy code did not trust the event status field");
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
        assert_eq!(
            agent_run_reconciliation_path(AgentRunContractVersion::V2, "FAILED", Some("FAILED"))
                .expect("v2 terminal owner path"),
            AgentRunReconciliationPath::V2Terminal
        );
    }
}
