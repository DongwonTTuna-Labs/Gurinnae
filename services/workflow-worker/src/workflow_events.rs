async fn handle_event(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
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
    let aggregate_id = value_uuid(&job.payload, "aggregateId")?;
    let payload = job
        .payload
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "payload is missing".to_owned()))?;
    let processed: bool = sqlx::query_scalar(
        "SELECT processed_at IS NOT NULL FROM ops.inbox \
         WHERE consumer='workflow-worker' AND event_id=$1",
    )
    .bind(event_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_MISSING", event_id.to_string()))?;
    if processed {
        return Ok(json!({"deduplicated":true,"eventId":event_id}));
    }

    let metrics = match event_type {
        "agent.run_completed.v1" => reconcile_agent_run(pool, payload).await?,
        "attachment.correction_scan_requested.v1" => {
            scan_attachment(pool, store, scanner, "CORRECTION", aggregate_id).await?
        }
        "attachment.response_scan_requested.v1" => {
            scan_attachment(pool, store, scanner, "RESPONSE", aggregate_id).await?
        }
        "audit.export_requested.v1" => export_audit(pool, store, aggregate_id).await?,
        "detection.signal_created.v1" => create_signal_task(pool, payload).await?,
        "export.dataset_requested.v1" => export_dataset(pool, store, aggregate_id).await?,
        "source.schema_drift_detected.v1" => reconcile_schema_drift(pool, payload).await?,
        "workflow.response_submitted.v1" => reconcile_response(pool, aggregate_id).await?,
        _ => {
            return Err(Failure::Terminal(
                "UNSUPPORTED_EVENT_TYPE",
                event_type.to_owned(),
            ));
        }
    };
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='workflow-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
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
    tracing::info!(%event_id,event_type,"workflow event reconciled");
    Ok(metrics)
}

async fn scan_attachment(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    kind: &str,
    id: Uuid,
) -> Result<Value, Failure> {
    let sql = match kind {
        "RESPONSE" => {
            "SELECT object_key,size_bytes,sha256::text FROM intake.response_attachments \
             WHERE id=$1 AND upload_status='FINALIZED' AND scan_status='PENDING'"
        }
        "CORRECTION" => {
            "SELECT object_key,size_bytes,sha256::text FROM intake.correction_draft_attachments \
             WHERE id=$1 AND upload_status='FINALIZED' AND scan_status='PENDING'"
        }
        _ => {
            return Err(Failure::Terminal(
                "ATTACHMENT_KIND_INVALID",
                kind.to_owned(),
            ));
        }
    };
    let row = sqlx::query(sql)
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(database)?
        .ok_or_else(|| Failure::Terminal("ATTACHMENT_NOT_PENDING", id.to_string()))?;
    let key: String = row.try_get("object_key").map_err(database)?;
    let expected_size: i64 = row.try_get("size_bytes").map_err(database)?;
    let expected_sha256: String = row.try_get::<String, _>("sha256").map_err(database)?;
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
    let event_id: Uuid = sqlx::query_scalar(
        "SELECT ops.enqueue_outbox('attachment',$1,1,'attachment.scan_completed.v1',$2,clock_timestamp())",
    )
    .bind(id.to_string())
    .bind(json!({"attachment_id":id,"attachment_kind":kind,"scan_status":status,
        "sha256":expected_sha256.trim()}))
    .fetch_one(pool)
    .await
    .map_err(database)?;
    tracing::info!(attachment_id=%id, attachment_kind=%kind, scan_status=status, %event_id, "attachment scan completed");
    Ok(json!({"attachmentId":id,"attachmentKind":kind,"scanStatus":status,"eventId":event_id}))
}

async fn reconcile_agent_run(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let run_id = object_uuid(payload, "agent_run_id")?;
    let case_id = object_uuid(payload, "case_id")?;
    let expected = payload
        .get("output_digest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or_else(|| Failure::Terminal("INVALID_AGENT_EVENT", "output digest".to_owned()))?;
    let row =
        sqlx::query("SELECT status,output_payload FROM ops.agent_runs WHERE id=$1 AND case_id=$2")
            .bind(run_id)
            .bind(case_id)
            .fetch_optional(pool)
            .await
            .map_err(database)?
            .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_FOUND", run_id.to_string()))?;
    let status: String = row.try_get("status").map_err(database)?;
    let output: Option<Value> = row.try_get("output_payload").map_err(database)?;
    if status != "SUCCEEDED" {
        return Err(Failure::Terminal("AGENT_RUN_NOT_SUCCEEDED", status));
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
    let suggestions: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM ops.agent_suggestions WHERE agent_run_id=$1 AND status='PENDING'",
    )
    .bind(run_id)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if suggestions > 0 {
        sqlx::query(
            "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority) \
             VALUES('AGENT_REVIEW','AGENT_RUN',$1,'Review agent suggestions','OPEN','NORMAL') \
             ON CONFLICT DO NOTHING",
        )
        .bind(run_id)
        .execute(pool)
        .await
        .map_err(database)?;
    }
    Ok(json!({"agentRunId":run_id,"suggestions":suggestions}))
}

