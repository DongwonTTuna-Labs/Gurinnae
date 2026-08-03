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
    let active: bool = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM core.rule_versions WHERE id=$1 AND status='ACTIVE')",
        target,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        database(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })?;
    if !active {
        return Err(Failure::Terminal(
            "RULE_VERSION_NOT_ACTIVE",
            target.to_string(),
        ));
    }
    let changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='analysis-worker' AND event_id=$1 AND processed_at IS NULL",
        event_id,
    )
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        let processed = sqlx::query_scalar!(
            "SELECT COALESCE(processed_at IS NOT NULL,false) FROM ops.inbox \
             WHERE consumer='analysis-worker' AND event_id=$1",
            event_id,
        )
        .fetch_optional(pool)
        .await
        .map_err(database)?;
        let processed = processed
            .map(required)
            .transpose()
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
    let row = sqlx::query!(
        "UPDATE core.rule_evaluations e SET status='RUNNING', \
           started_at=COALESCE(started_at,clock_timestamp()) \
         FROM core.rule_versions v WHERE e.id=$1 AND e.rule_version_id=v.id \
           AND e.status IN ('QUEUED','RUNNING') \
         RETURNING e.rule_version_id,e.dataset_snapshot_id,e.requester_type, \
                   v.rule_id,v.configuration,v.code_digest",
        evaluation_id,
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RULE_EVALUATION_NOT_QUEUED", evaluation_id.to_string()))?;
    let rule_version_id = row.rule_version_id;
    let dataset_snapshot_id = row.dataset_snapshot_id;
    let rule_id = row.rule_id;
    let configuration = row.configuration;
    let (result, input_digest, result_digest, snapshot_binding) = if row.requester_type == "SERVICE"
    {
        let input = analysis_rule_evaluation_v2::load_snapshot_rule_input(
            &mut tx,
            dataset_snapshot_id,
            rule_version_id,
            &rule_id,
            &configuration,
            row.code_digest.trim(),
        )
        .await?;
        let (result, input_digest, result_digest) =
            evaluate_snapshot_rule_input(&rule_id, &input.value, &input.input_sha256)?;
        let binding = SnapshotRunBinding {
            snapshot_sha256: input.snapshot_sha256,
            rule_configuration_sha256: input.rule_configuration_sha256,
            rule_code_sha256: input.rule_code_sha256,
        };
        (result, input_digest, result_digest, Some(binding))
    } else {
        let (result, input_digest, result_digest) = evaluate_rule_input(&rule_id, &configuration)?;
        (result, input_digest, result_digest, None)
    };
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
        snapshot_binding.as_ref(),
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

struct SnapshotRunBinding {
    snapshot_sha256: String,
    rule_configuration_sha256: String,
    rule_code_sha256: String,
}

fn evaluate_snapshot_rule_input(
    rule_id: &str,
    input: &Value,
    expected_input_sha256: &str,
) -> Result<(Value, String, String), Failure> {
    let result = gurine_detection::engine::evaluate(rule_id, input)
        .map_err(|error| Failure::Terminal("RULE_EVALUATION_INVALID", error.to_string()))?;
    let input_digest = result
        .get("input_hash")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64)
        .ok_or_else(|| Failure::Terminal("RULE_INPUT_HASH_MISSING", rule_id.to_owned()))?
        .to_owned();
    if input_digest != expected_input_sha256 {
        return Err(Failure::Terminal(
            "RULE_INPUT_HASH_MISMATCH",
            rule_id.to_owned(),
        ));
    }
    let result_digest = result
        .get("result_hash")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64)
        .ok_or_else(|| Failure::Terminal("RULE_RESULT_HASH_MISSING", rule_id.to_owned()))?
        .to_owned();
    Ok((result, input_digest, result_digest))
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
    snapshot_binding: Option<&SnapshotRunBinding>,
) -> Result<(Uuid, i64), Failure> {
    let snapshot_sha256 = snapshot_binding.map(|binding| binding.snapshot_sha256.as_str());
    let configuration_sha256 =
        snapshot_binding.map(|binding| binding.rule_configuration_sha256.as_str());
    let code_sha256 = snapshot_binding.map(|binding| binding.rule_code_sha256.as_str());
    let v2_snapshot_id = snapshot_binding.map(|_| dataset_snapshot_id);
    let run_id: Uuid = sqlx::query_scalar!(
        "INSERT INTO core.rule_runs( \
           rule_version_id,run_key,input_snapshot_at,input_digest,started_at,status, \
           dataset_snapshot_id,dataset_snapshot_sha256,rule_configuration_sha256,rule_code_sha256) \
         VALUES($1,$2,clock_timestamp(),$3,clock_timestamp(),'RUNNING',$4,$5,$6,$7) \
         ON CONFLICT(run_key) DO UPDATE SET input_digest=EXCLUDED.input_digest \
         WHERE core.rule_runs.status='RUNNING' \
           AND core.rule_runs.input_digest=EXCLUDED.input_digest \
           AND core.rule_runs.dataset_snapshot_id IS NOT DISTINCT FROM EXCLUDED.dataset_snapshot_id \
           AND core.rule_runs.dataset_snapshot_sha256 IS NOT DISTINCT FROM EXCLUDED.dataset_snapshot_sha256 \
           AND core.rule_runs.rule_configuration_sha256 IS NOT DISTINCT FROM EXCLUDED.rule_configuration_sha256 \
           AND core.rule_runs.rule_code_sha256 IS NOT DISTINCT FROM EXCLUDED.rule_code_sha256 \
         RETURNING id",
        rule_version_id,
        format!("evaluation:{evaluation_id}"),
        input_digest,
        v2_snapshot_id,
        snapshot_sha256,
        configuration_sha256,
        code_sha256,
    )
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
        snapshot_binding,
    )
    .await?;
    Ok((run_id, signal_count))
}
include!("analysis_signal_persistence.rs");
async fn finish_rule_evaluation(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    evaluation_id: Uuid,
    run_id: Uuid,
    signal_count: i64,
    result: &Value,
    result_digest: &str,
) -> Result<(), Failure> {
    sqlx::query!(
        "UPDATE core.rule_runs SET status='SUCCEEDED',completed_at=clock_timestamp(),            record_count=1,signal_count=$2 WHERE id=$1 AND status='RUNNING'",
        run_id,
        signal_count,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "UPDATE core.rule_evaluations SET status='SUCCEEDED',result_payload=$2,result_digest=$3,            completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
        evaluation_id,
        result,
        result_digest,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}
include!("analysis_agent_jobs.rs");
