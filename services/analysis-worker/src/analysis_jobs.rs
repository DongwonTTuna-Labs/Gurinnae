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
struct AgentContext {
    job_id: Uuid,
    run_id: Uuid,
    run_version: i64,
    case_id: Uuid,
    agent_type: String,
    objective: String,
    evidence: Value,
    expected_snapshot: String,
    current_snapshot: String,
    maximum_cost_krw: i64,
    allowed_ids: Vec<String>,
    locator_map: serde_json::Map<String, Value>,
    input: Value,
    transcript: Value,
}
async fn agent_run(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    let context = load_agent_context(state, job).await?;
    let (provider, model, provider_output, actual_cost, provider_available) =
        select_agent_output(state, &context).await?;
    validate_agent_output(&provider_output)?;
    let output = apply_agent_policy(
        &context,
        &provider,
        &provider_output,
        actual_cost,
        provider_available,
    )?;
    validate_agent_output(&output)?;
    let status = agent_status(&output)?;
    let digest = sha256(&canonical_bytes(&output)?);
    persist_agent_run(
        state,
        &context,
        &provider,
        &model,
        &output,
        status,
        actual_cost,
        &digest,
    )
    .await?;
    Ok(json!({
        "agentRunId":context.run_id,
        "status":status,
        "outputDigest":digest,
        "provider":provider
    }))
}
/// Materialise the pre-dispatch TOOL_QUERY authorization receipts in the same
/// run before any provider request is assembled.  This is deliberately
/// idempotent and resolves the selected segment and current asset-rights leaf
/// from the verified evidence rows; a missing/expired/denied rights decision
/// leaves no usable root and the subsequent snapshot gate fails closed.
fn agent_inputs(
    evidence: &Value,
    evidence_ids: &[Uuid],
    current_snapshot: String,
    maximum_cost_krw: i64,
    agent_type: &str,
) -> Result<AgentInputBundle, Failure> {
    let policy_flags = evidence
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|item| {
            item.get("promptInjectionFlags")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    let locator_map = evidence
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| Some((item.get("id")?.as_str()?, item.get("locator")?.as_str()?)))
        .map(|(id, locator)| (id.to_owned(), json!([locator])))
        .collect::<serde_json::Map<_, _>>();
    let allowed_ids = evidence_ids.iter().map(Uuid::to_string).collect::<Vec<_>>();
    if !matches!(
        agent_type,
        "market-researcher" | "investigator" | "skeptic" | "claim-drafter" | "citation-verifier"
    ) {
        return Err(Failure::Terminal(
            "AGENT_TYPE_UNKNOWN",
            agent_type.to_owned(),
        ));
    }
    let input = json!({
        "evidence_snapshot_hash":current_snapshot,
        "allowed_evidence_ids":allowed_ids,
        "budget_krw":maximum_cost_krw,
        "policy_flags":if policy_flags.is_empty(){json!([])}else{json!(["prompt_injection_detected"])},
    });
    // The provider may cite only an evidence item returned by an allow-listed
    // read adapter.  Materialize the immutable snapshot rows as the initial
    // read receipts; later tool turns append to this transcript through the
    // typed dispatcher.
    let calls = evidence
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| {
            Some(json!({
                // Market research is authorized to discover evidence through
                // the search adapter; the other agents consume the already
                // selected snapshot through evidence.read.
                "tool_id":if agent_type == "market-researcher" {"evidence.search"} else {"evidence.read"},
                "mode":"READ_ONLY",
                "cost_krw":0,
                "request":{"evidenceId":item.get("id")?},
                "response":{"results":[{"id":item.get("id")?,"locator":item.get("locator")?}]}
            }))
        })
        .collect::<Vec<_>>();
    let transcript = json!({"calls": calls});
    Ok((allowed_ids, locator_map, input, transcript))
}
async fn select_agent_output(
    state: &State,
    context: &AgentContext,
) -> Result<(String, String, Value, i64, bool), Failure> {
    if context.expected_snapshot != context.current_snapshot {
        return Ok((
            "none".to_owned(),
            "none".to_owned(),
            blocked_output("ABSTAINED", "EVIDENCE_SNAPSHOT_STALE"),
            0,
            false,
        ));
    }
    // A zero (or negative) run envelope is terminal before any provider,
    // deterministic double, or policy evaluation is entered.  Keeping this
    // fence here makes the persisted state explicitly BUDGET_BLOCKED rather
    // than turning an exhausted run into the generic test-environment
    // AI_NOT_ACTIVATED response.
    if context.maximum_cost_krw <= 0 {
        return Ok((
            "none".to_owned(),
            "none".to_owned(),
            blocked_output("BUDGET_BLOCKED", "BUDGET_EXHAUSTED"),
            0,
            false,
        ));
    }
    if !state.config.ai_enabled {
        return Ok((
            "none".to_owned(),
            "none".to_owned(),
            blocked_output("POLICY_BLOCKED", "AI_DISABLED"),
            0,
            false,
        ));
    }
    if matches!(state.config.environment.as_str(), "development" | "test") {
        return Ok((
            "deterministic".to_owned(),
            "authority-double-v1".to_owned(),
            deterministic_output(&context.evidence),
            0,
            true,
        ));
    }
    production_provider(
        state,
        context.run_id,
        context.job_id,
        context.case_id,
        &context.agent_type,
        &context.objective,
        &context.evidence,
        &context.current_snapshot,
        context.maximum_cost_krw,
    )
    .await
}
fn apply_agent_policy(
    context: &AgentContext,
    provider: &str,
    provider_output: &Value,
    actual_cost: i64,
    provider_available: bool,
) -> Result<Value, Failure> {
    if matches!(
        provider_output.get("status").and_then(Value::as_str),
        Some("POLICY_BLOCKED" | "BUDGET_BLOCKED")
    ) || context.expected_snapshot != context.current_snapshot
    {
        return Ok(provider_output.clone());
    }
    let scenario = json!({
        "kind":"normal","current_evidence_snapshot_hash":context.current_snapshot,
        "provider_attempts":[{"provider":provider,"status":if provider_available{"OK"}else{"UNAVAILABLE"},"cost_krw":actual_cost}],
        "expected_locator_map":Value::Object(context.locator_map.clone()),"max_iterations":16
    });
    policy::evaluate(EvaluationContext {
        agent_id: &context.agent_type,
        scenario: &scenario,
        input: &context.input,
        provider_output,
        transcript: &context.transcript,
    })
    .map_err(|error| Failure::Terminal("AGENT_POLICY_INVALID", error.to_string()))
}

fn agent_status(output: &Value) -> Result<&'static str, Failure> {
    match output.get("status").and_then(Value::as_str) {
        Some("BUDGET_BLOCKED") => Ok("BUDGET_BLOCKED"),
        Some("POLICY_BLOCKED") => Ok("POLICY_BLOCKED"),
        Some("COMPLETED" | "ABSTAINED") => Ok("SUCCEEDED"),
        _ => Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "status".into())),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "agent completion persists output, provider, cost, and digest atomically"
)]
async fn persist_agent_run(
    state: &State,
    context: &AgentContext,
    provider: &str,
    model: &str,
    output: &Value,
    status: &str,
    actual_cost: i64,
    digest: &str,
) -> Result<(), Failure> {
    let mut tx = state.pool.begin().await.map_err(database)?;
    let changed: bool = sqlx::query_scalar(
        "SELECT ops.transition_agent_run_worker_v1($1,$2,$3,$4,$5,$6,$7,$8,true)",
    )
    .bind(context.run_id)
    .bind(context.run_version)
    .bind(status)
    .bind(provider)
    .bind(model)
    .bind(output)
    .bind("v1")
    .bind(Decimal::from(actual_cost))
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    if !changed {
        return Err(Failure::Terminal(
            "AGENT_RUN_FENCE_FAILED",
            context.run_id.to_string(),
        ));
    }
    persist_agent_suggestion(&mut tx, context, output).await?;
    sqlx::query(
        "SELECT ops.enqueue_outbox('agent_run',$1,1,'agent.run_completed.v1',$2,clock_timestamp())",
    )
    .bind(context.run_id.to_string())
    .bind(json!({
        "agent_run_id":context.run_id,
        "case_id":context.case_id,
        "output_digest":digest,
        "status":status
    }))
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)
}

async fn persist_agent_suggestion(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    context: &AgentContext,
    output: &Value,
) -> Result<(), Failure> {
    if output.get("status").and_then(Value::as_str) != Some("COMPLETED") {
        return Ok(());
    }
    sqlx::query(
        "INSERT INTO ops.agent_suggestions(agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status)          VALUES($1,$2,$3,$4,$5,$6,'PENDING')",
    )
    .bind(context.run_id)
    .bind(context.case_id)
    .bind(context.agent_type.to_uppercase().replace('-', "_"))
    .bind(output)
    .bind(json!(context.allowed_ids))
    .bind(output.get("citations").cloned().unwrap_or_else(|| json!([])))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}
