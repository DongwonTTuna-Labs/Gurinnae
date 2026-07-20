async fn activation_event(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    if job.payload.get("eventType").and_then(Value::as_str)
        != Some("workflow.rule_activation_applied.v1")
    {
        return Err(Failure::Terminal(
            "INVALID_RULE_ACTIVATION_EVENT",
            "event type".to_owned(),
        ));
    }
    let event_id = pointer_uuid(&job.payload, "/eventId")?;
    let target = pointer_uuid(&job.payload, "/payload/targetVersionId")?;
    let operation = job
        .payload
        .pointer("/payload/operation_id")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "activateRuleVersion" | "rollbackRuleVersion"))
        .ok_or_else(|| Failure::Terminal("INVALID_RULE_ACTIVATION_EVENT", "operation".into()))?;
    let active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM core.rule_versions WHERE id=$1 AND status='ACTIVE')",
    )
    .bind(target)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if !active {
        return Err(Failure::Terminal(
            "RULE_VERSION_NOT_ACTIVE",
            target.to_string(),
        ));
    }
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='analysis-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        let processed: bool = sqlx::query_scalar(
            "SELECT COALESCE(processed_at IS NOT NULL,false) FROM ops.inbox \
             WHERE consumer='analysis-worker' AND event_id=$1",
        )
        .bind(event_id)
        .fetch_optional(pool)
        .await
        .map_err(database)?
        .unwrap_or(false);
        if !processed {
            return Err(Failure::Terminal(
                "INBOX_FENCE_FAILED",
                event_id.to_string(),
            ));
        }
    }
    Ok(json!({"eventId":event_id,"ruleVersionId":target,"operationId":operation}))
}
async fn rule_evaluation(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    let evaluation_id = payload_uuid(&job.payload, "evaluationId")?;
    let mut tx = pool.begin().await.map_err(database)?;
    let row = sqlx::query(
        "UPDATE core.rule_evaluations e SET status='RUNNING',            started_at=COALESCE(started_at,clock_timestamp())          FROM core.rule_versions v WHERE e.id=$1 AND e.rule_version_id=v.id            AND e.status IN ('QUEUED','RUNNING')          RETURNING e.rule_version_id,e.dataset_snapshot_id,v.rule_id,v.configuration",
    )
    .bind(evaluation_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RULE_EVALUATION_NOT_QUEUED", evaluation_id.to_string()))?;
    let (rule_version_id, dataset_snapshot_id, rule_id, configuration) = parse_rule_row(&row)?;
    let (result, input_digest, result_digest) = evaluate_rule_input(&rule_id, &configuration)?;
    let (run_id, signal_count) = persist_rule_run(
        &mut tx,
        evaluation_id,
        rule_version_id,
        dataset_snapshot_id,
        &rule_id,
        &configuration,
        &result,
        &input_digest,
        &result_digest,
    )
    .await?;
    finish_rule_evaluation(
        &mut tx,
        evaluation_id,
        run_id,
        signal_count,
        &result,
        &result_digest,
    )
    .await?;
    tx.commit().await.map_err(database)?;
    Ok(json!({
        "evaluationId":evaluation_id,
        "runId":run_id,
        "signalCount":signal_count,
        "resultDigest":result_digest
    }))
}
fn parse_rule_row(row: &sqlx::postgres::PgRow) -> Result<(Uuid, Uuid, String, Value), Failure> {
    Ok((
        row.try_get("rule_version_id").map_err(database)?,
        row.try_get("dataset_snapshot_id").map_err(database)?,
        row.try_get("rule_id").map_err(database)?,
        row.try_get("configuration").map_err(database)?,
    ))
}
fn evaluate_rule_input(
    rule_id: &str,
    configuration: &Value,
) -> Result<(Value, String, String), Failure> {
    let input = configuration
        .get("evaluationInput")
        .ok_or_else(|| Failure::Terminal("RULE_INPUT_MISSING", rule_id.to_owned()))?;
    let result = gurine_detection::engine::evaluate(rule_id, input)
        .map_err(|error| Failure::Terminal("RULE_EVALUATION_INVALID", error.to_string()))?;
    let input_digest = sha256(&canonical_bytes(input)?);
    let result_digest = sha256(&canonical_bytes(&result)?);
    Ok((result, input_digest, result_digest))
}
#[expect(
    clippy::too_many_arguments,
    reason = "rule-run persistence receives the immutable evaluation provenance fields"
)]
async fn persist_rule_run(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    evaluation_id: Uuid,
    rule_version_id: Uuid,
    dataset_snapshot_id: Uuid,
    rule_id: &str,
    configuration: &Value,
    result: &Value,
    input_digest: &str,
    result_digest: &str,
) -> Result<(Uuid, i64), Failure> {
    let run_id: Uuid = sqlx::query_scalar(
        "INSERT INTO core.rule_runs(rule_version_id,run_key,input_snapshot_at,input_digest,            started_at,status) VALUES($1,$2,clock_timestamp(),$3,clock_timestamp(),'RUNNING')          ON CONFLICT(run_key) DO UPDATE SET input_digest=EXCLUDED.input_digest          WHERE core.rule_runs.status='RUNNING' RETURNING id",
    )
    .bind(rule_version_id)
    .bind(format!("evaluation:{evaluation_id}"))
    .bind(input_digest)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RULE_RUN_ALREADY_TERMINAL", evaluation_id.to_string()))?;
    let signal_count = persist_signal(
        tx,
        run_id,
        rule_version_id,
        dataset_snapshot_id,
        rule_id,
        configuration,
        result,
        result_digest,
    )
    .await?;
    Ok((run_id, signal_count))
}
#[expect(
    clippy::too_many_arguments,
    reason = "signal persistence receives rule, snapshot, and evidence provenance"
)]
async fn persist_signal(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    run_id: Uuid,
    rule_version_id: Uuid,
    dataset_snapshot_id: Uuid,
    rule_id: &str,
    configuration: &Value,
    result: &Value,
    result_digest: &str,
) -> Result<i64, Failure> {
    if result.get("outcome").and_then(Value::as_str) != Some("SIGNAL") {
        return Ok(0);
    }
    let target_id = result
        .pointer("/included_ids/0")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or(dataset_snapshot_id);
    let severity = configuration
        .get("severity")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "INFO" | "LOW" | "MEDIUM" | "HIGH" | "CRITICAL"))
        .unwrap_or("HIGH");
    let inserted: Option<Uuid> = sqlx::query_scalar(
        "INSERT INTO core.anomaly_signals(id,rule_run_id,rule_version_id,signal_type,            target_type,target_id,severity,explanation,calculation,blockers,comparison_digest)          VALUES($1,$2,$3,$4,'DATASET_SNAPSHOT',$5,$6,$7,$8,$9,$10)          ON CONFLICT(rule_version_id,target_type,target_id,comparison_digest) DO NOTHING          RETURNING id",
    )
    .bind(Uuid::new_v4())
    .bind(run_id)
    .bind(rule_version_id)
    .bind(rule_id)
    .bind(target_id)
    .bind(severity)
    .bind(json!({"outcome":"SIGNAL","includedIds":result["included_ids"]}))
    .bind(result.get("metrics").cloned().unwrap_or_else(|| json!({})))
    .bind(result.get("blockers").cloned().unwrap_or_else(|| json!([])))
    .bind(result_digest)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?;
    if let Some(signal_id) = inserted {
        sqlx::query(
            "SELECT ops.enqueue_outbox('signal',$1,1,'detection.signal_created.v1',$2,clock_timestamp())",
        )
        .bind(signal_id.to_string())
        .bind(json!({
            "signal_id":signal_id,"rule_version_id":rule_version_id,"target_id":target_id
        }))
        .fetch_one(&mut **tx)
        .await
        .map_err(database)?;
        return Ok(1);
    }
    Ok(0)
}
async fn finish_rule_evaluation(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    evaluation_id: Uuid,
    run_id: Uuid,
    signal_count: i64,
    result: &Value,
    result_digest: &str,
) -> Result<(), Failure> {
    sqlx::query(
        "UPDATE core.rule_runs SET status='SUCCEEDED',completed_at=clock_timestamp(),            record_count=1,signal_count=$2 WHERE id=$1 AND status='RUNNING'",
    )
    .bind(run_id)
    .bind(signal_count)
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "UPDATE core.rule_evaluations SET status='SUCCEEDED',result_payload=$2,result_digest=$3,            completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
    )
    .bind(evaluation_id)
    .bind(result)
    .bind(result_digest)
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}
include!("analysis_agent_jobs.rs");
