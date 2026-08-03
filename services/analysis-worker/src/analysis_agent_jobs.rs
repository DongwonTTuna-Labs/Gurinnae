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
    validate_agent_output_for(Some(context.agent_type.as_str()), &provider_output)?;
    let output = apply_agent_policy(
        &context,
        &provider,
        &provider_output,
        actual_cost,
        provider_available,
    )?;
    validate_agent_output_for(Some(context.agent_type.as_str()), &output)?;
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
            blocked_output_for(&context.agent_type, "POLICY_BLOCKED", "EVIDENCE_SNAPSHOT_STALE"),
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
            blocked_output_for(&context.agent_type, "BUDGET_BLOCKED", "BUDGET_EXHAUSTED"),
            0,
            false,
        ));
    }
    // AI/model routing has its own durable incident fence.  A switch is
    // evaluated immediately before any deterministic or external provider
    // path, so disabling the model tier cannot be bypassed by the local test
    // double.  The core deterministic rule pipeline remains unaffected.
    if let Some(code) = active_ai_kill_switch(state, &context.agent_type).await? {
        return Ok((
            "none".to_owned(),
            "none".to_owned(),
            blocked_output_for(&context.agent_type, "POLICY_BLOCKED", &code),
            0,
            false,
        ));
    }
    if !state.config.ai_enabled {
        return Ok((
            "none".to_owned(),
            "none".to_owned(),
            blocked_output_for(&context.agent_type, "POLICY_BLOCKED", "AI_DISABLED"),
            0,
            false,
        ));
    }
    if matches!(state.config.environment.as_str(), "development" | "test") {
        return Ok((
            "deterministic".to_owned(),
            "authority-double-v1".to_owned(),
            deterministic_output(&context.agent_type, &context.evidence),
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

async fn active_ai_kill_switch(
    state: &State,
    agent_type: &str,
) -> Result<Option<String>, Failure> {
    sqlx::query_scalar!(
        "SELECT code FROM ops.kill_switches k
         WHERE k.state='ACTIVE'
           AND (k.expires_at IS NULL OR k.expires_at > clock_timestamp())
           AND (
             k.scope='{}'::jsonb
             OR k.code ILIKE 'AI_%'
             OR k.code ILIKE '%_AI_%'
             OR k.code ILIKE '%MODEL%'
             OR k.code ILIKE '%AGENT%'
             OR k.scope ? 'ai'
             OR k.scope ? 'model'
             OR k.scope ? 'agent'
             OR (k.scope->'agentTypes') ? $1
             OR k.scope @> jsonb_build_object('agentType',$1)
           )
         ORDER BY k.activated_at DESC NULLS LAST, k.code
         LIMIT 1",
        agent_type,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(database)
}
fn apply_agent_policy(
    context: &AgentContext,
    provider: &str,
    provider_output: &Value,
    actual_cost: i64,
    provider_available: bool,
) -> Result<Value, Failure> {
    let blocked_code = abstention_reason_code(provider_output);
    if matches!(
        provider_output
            .get("status")
            .or_else(|| provider_output.get("outcome"))
            .and_then(Value::as_str),
        Some("POLICY_BLOCKED" | "BUDGET_BLOCKED")
    ) || matches!(blocked_code, Some("POLICY_BLOCKED" | "BUDGET_BLOCKED" | "BUDGET_EXHAUSTED" | "AI_DISABLED" | "PROVIDER_UNAVAILABLE" | "EVIDENCE_SNAPSHOT_STALE"))
        || context.expected_snapshot != context.current_snapshot
    {
        return Ok(provider_output.clone());
    }
    let scenario = json!({
        "kind":"normal","current_evidence_snapshot_hash":context.current_snapshot,
        "provider_attempts":[{"provider":provider,"status":if provider_available{"OK"}else{"UNAVAILABLE"},"cost_krw":actual_cost}],
        "expected_locator_map":Value::Object(context.locator_map.clone()),"max_iterations":16
    });
    let policy_view = policy_view_for_output(&context.evidence, provider_output)?;
    let evaluated = policy::evaluate(EvaluationContext {
        agent_id: &context.agent_type,
        scenario: &scenario,
        input: &context.input,
        provider_output: &policy_view,
        transcript: &context.transcript,
    })
    .map_err(|error| Failure::Terminal("AGENT_POLICY_INVALID", error.to_string()))?;
    if evaluated
        .get("status")
        .and_then(Value::as_str)
        .is_some_and(|status| status != "COMPLETED")
    {
        return Ok(normalize_policy_result(&context.agent_type, &evaluated));
    }
    Ok(provider_output.clone())
}

/// The policy module deliberately exposes a transport-neutral, snake_case
/// result.  Agent runs, however, persist the selected agent's closed V2
/// output schema.  Normalize policy denials at this boundary so a policy
/// decision cannot turn into a schema failure (or accidentally be treated as
/// a successful agent result).
fn normalize_policy_result(agent_type: &str, evaluated: &Value) -> Value {
    let status = match evaluated.get("status").and_then(Value::as_str) {
        Some("BUDGET_BLOCKED") => "BUDGET_BLOCKED",
        Some("POLICY_BLOCKED") => "POLICY_BLOCKED",
        _ => "ABSTAINED",
    };
    let reason = evaluated
        .get("abstention_reasons")
        .or_else(|| evaluated.get("abstentionReasons"))
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(Value::as_str)
        .unwrap_or("INSUFFICIENT_EVIDENCE");
    blocked_output_for(agent_type, status, reason)
}

fn policy_view_for_output(evidence: &Value, output: &Value) -> Result<Value, Failure> {
    if output.get("schemaVersion").is_none() {
        return Ok(output.clone());
    }
    let mut citations = Vec::new();
    for citation in output["citations"].as_array().into_iter().flatten() {
        let source_sha = citation
            .get("sourceUseSha256")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", "sourceUseSha256".into()))?;
        let Some((evidence_id, locator)) = evidence
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|item| {
                let uses = item.get("sourceUses")?.as_array()?;
                let matches = uses.iter().any(|use_row| use_row.get("sourceUseSha256").and_then(Value::as_str) == Some(source_sha));
                if matches {
                    Some((item.get("id")?.clone(), citation.pointer("/locator/value")?.clone()))
                } else {
                    None
                }
            })
            .next()
        else {
            return Err(Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", "citation source".into()));
        };
        citations.push(json!({"evidence_id":evidence_id,"locator":locator,"supports":citation.get("supports")}));
    }
    Ok(json!({
        "status": output.get("outcome").or_else(|| output.get("status")),
        "summary": output.get("summary"),
        "citations": citations,
        "unknowns": output.get("unknowns").cloned().unwrap_or_else(|| json!([])),
        "abstention_reasons": output.get("abstentionReasons").cloned().unwrap_or_else(|| json!([])),
        "recommended_actions": []
    }))
}

fn agent_status(output: &Value) -> Result<&'static str, Failure> {
    let reason_code = abstention_reason_code(output);
    if matches!(reason_code, Some("BUDGET_BLOCKED" | "BUDGET_EXHAUSTED")) {
        return Ok("BUDGET_BLOCKED");
    }
    if matches!(reason_code, Some("POLICY_BLOCKED" | "AI_DISABLED" | "EVIDENCE_SNAPSHOT_STALE" | "PROVIDER_UNAVAILABLE")) {
        return Ok("POLICY_BLOCKED");
    }
    match output
        .get("status")
        .or_else(|| output.get("outcome"))
        .and_then(Value::as_str)
    {
        Some("BUDGET_BLOCKED") => Ok("BUDGET_BLOCKED"),
        Some("POLICY_BLOCKED") => Ok("POLICY_BLOCKED"),
        Some("COMPLETED" | "ABSTAINED") => Ok("SUCCEEDED"),
        _ => Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "status".into())),
    }
}

fn abstention_reason_code(output: &Value) -> Option<&str> { output.get("abstentionReasons").and_then(Value::as_array).and_then(|items| items.first()).and_then(|item| item.as_str().or_else(|| item.get("code").and_then(Value::as_str))) }

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
    let changed: bool = sqlx::query_scalar!(
        "SELECT ops.transition_agent_run_worker_v1($1,$2,$3,$4,$5,$6,$7,$8,true)",
        context.run_id,
        context.run_version,
        status,
        provider,
        model,
        output,
        "v1",
        Decimal::from(actual_cost),
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| database(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?;
    if !changed {
        return Err(Failure::Terminal(
            "AGENT_RUN_FENCE_FAILED",
            context.run_id.to_string(),
        ));
    }
    persist_agent_suggestion(&mut tx, context, output).await?;
    sqlx::query!(
        "SELECT ops.enqueue_outbox('agent_run',$1,1,'agent.run_completed.v1',$2,clock_timestamp())",
        context.run_id.to_string(),
        json!({
            "agent_run_id":context.run_id,
            "case_id":context.case_id,
            "output_digest":digest,
            "status":status
        }),
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)
}
