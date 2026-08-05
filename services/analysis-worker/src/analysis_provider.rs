#[path = "analysis_provider_response.rs"]
mod analysis_provider_response;

use analysis_provider_response::provider_response_body;

#[expect(
    clippy::too_many_arguments,
    reason = "provider selection binds job, case, routing, budget, and immutable evidence context"
)]
async fn production_provider(
    state: &State,
    run_id: Uuid,
    job_id: Uuid,
    case_id: Uuid,
    agent_type: &str,
    objective: &str,
    evidence: &Value,
    input_snapshot_sha256: &str,
    maximum_cost_krw: i64,
) -> Result<(String, String, Value, i64, bool), Failure> {
    let rows = sqlx::query!(
        "SELECT id,provider_type,name,routing_policy,version FROM ops.provider_configs WHERE enabled",
    )
    .fetch_all(&state.pool)
    .await
    .map_err(database)?;
    let gateway = provider_gateway(state, run_id)?;
    let mut semantic_request = json!({
        "agentRunId": run_id,
        "agentType": agent_type,
        "objective": objective,
        "evidence": evidence,
        "maxCostKrw": maximum_cost_krw,
        "responseFormat": output_schema_contract(agent_type).1,
    });
    redact_provider_payload(&mut semantic_request);
    let semantic_request_sha256 = sha256(&canonical_bytes(&semantic_request)?);
    for requested in &state.config.provider_order {
        let Some(row) = rows.iter().find(|row| {
            row.provider_type.eq_ignore_ascii_case(requested)
                || row.name.eq_ignore_ascii_case(requested)
        }) else {
            continue;
        };
        let provider = row.provider_type.clone();
        let provider_config_id = row.id;
        let routing = row.routing_policy.clone();
        let Some(target) = routing.get("targetUrl").and_then(Value::as_str) else {
            continue;
        };
        let Some(model) = routing
            .get("model")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_owned)
        else {
            continue;
        };
        let routing_version = row.version;
        let request = ProviderRequestContext {
            state,
            gateway,
            run_id,
            job_id,
            case_id,
            agent_type,
            objective,
            evidence,
            maximum_cost_krw,
            semantic_request_sha256: &semantic_request_sha256,
            provider: &provider,
            provider_config_id,
            target,
            model: &model,
            routing_version,
            input_snapshot_sha256,
            routing_policy: &routing,
        };
        let Some((output, actual_cost)) = request_provider(&request).await? else {
            continue;
        };
        return Ok((provider, model, output, actual_cost, true));
    }
    Ok((
        "none".to_owned(),
        "none".to_owned(),
        blocked_output_for(agent_type, "POLICY_BLOCKED", "PROVIDER_UNAVAILABLE"),
        0,
        false,
    ))
}

fn provider_gateway(state: &State, run_id: Uuid) -> Result<&reqwest::Url, Failure> {
    state
        .config
        .egress_ai_url
        .as_ref()
        .ok_or_else(|| Failure::Terminal("AI_EGRESS_MISSING", run_id.to_string()))
}

struct ProviderRequestContext<'a> {
    state: &'a State,
    gateway: &'a reqwest::Url,
    run_id: Uuid,
    job_id: Uuid,
    case_id: Uuid,
    agent_type: &'a str,
    objective: &'a str,
    evidence: &'a Value,
    maximum_cost_krw: i64,
    semantic_request_sha256: &'a str,
    provider: &'a str,
    provider_config_id: Uuid,
    target: &'a str,
    model: &'a str,
    routing_version: i64,
    input_snapshot_sha256: &'a str,
    routing_policy: &'a Value,
}

async fn request_provider(
    context: &ProviderRequestContext<'_>,
) -> Result<Option<(Value, i64)>, Failure> {
    let pricing = LocalPricing::from_routing_policy(context.routing_policy)?;
    let relay_data_policy = if context.provider == RELAY_PROVIDER {
        Some(RelayDataPolicy::from_routing_policy(
            context.routing_policy,
        )?)
    } else {
        None
    };
    let mut prior_transcript_sha256 = sha256(b"{\"calls\":[]}");
    let mut prior_tool_result: Option<Value> = None;
    let mut total_cost = 0_i64;
    let max_provider_turns = agent_max_provider_turns(context.agent_type);
    for turn_sequence in 1..=max_provider_turns {
        let turn = insert_provider_turn(
            context.state,
            context.run_id,
            context.job_id,
            context.case_id,
            context.agent_type,
            context.objective,
            context.evidence,
            context.provider,
            context.provider_config_id,
            context.model,
            context.routing_version,
            context.input_snapshot_sha256,
            context.maximum_cost_krw.saturating_sub(total_cost),
            context.semantic_request_sha256,
            &context.state.config.environment,
            turn_sequence,
            &prior_transcript_sha256,
            prior_tool_result.as_ref(),
        )
        .await?;
        // Bind the selected evidence to this provider turn before any bytes
        // leave the process. A deterministic pre-dispatch receipt identity
        // keeps failed dispatches auditable, and completion promotes the same
        // MODEL_INPUT row, so there is never an unbound input row.
        {
            let mut lineage_tx = context.state.pool.begin().await.map_err(database)?;
            insert_model_input_source_uses(&mut lineage_tx, &turn, None, None).await?;
            lineage_tx.commit().await.map_err(database)?;
        }
        let response = send_provider_request(context, &turn, prior_tool_result.as_ref()).await?;
        let (output, cost, next_transcript, tool_result) = finalize_provider_response(
            context,
            response,
            &turn,
            context.maximum_cost_krw.saturating_sub(total_cost),
            &pricing,
            relay_data_policy.as_ref(),
        )
        .await?;
        total_cost = total_cost.saturating_add(cost);
        if let Some(output) = output {
            return Ok(Some((output, total_cost)));
        }
        prior_transcript_sha256 = next_transcript.ok_or_else(|| {
            Failure::Retryable("AGENT_RUNTIME_NOT_TERMINAL", turn.turn_id.to_string())
        })?;
        prior_tool_result = tool_result;
    }
    Ok(Some((
        blocked_output_for(context.agent_type, "ABSTAINED", "ITERATION_LIMIT_REACHED"),
        total_cost,
    )))
}

fn agent_max_provider_turns(agent_type: &str) -> i32 {
    match agent_type {
        "market-researcher" | "skeptic" => 12,
        "investigator" => 16,
        "claim-drafter" => 8,
        "citation-verifier" => 10,
        _ => 1,
    }
}

struct PreparedProviderRequest {
    body: Value,
    request_sha256: String,
    input_snapshot_id: Uuid,
}

async fn prepare_provider_request(
    context: &ProviderRequestContext<'_>,
    turn: &ProviderTurnIdentity,
    prior_tool_result: Option<&Value>,
) -> Result<PreparedProviderRequest, Failure> {
    // `insert_provider_turn` already persisted and hashed the exact semantic
    // request, including the selected authorized bytes. Sending that value
    // verbatim preserves the request_sha256/wire equality contract.
    let mut body = provider_wire_request(
        &turn.request_redacted,
        context.evidence,
        context.state.object_store.as_ref(),
        &context.state.pool,
        context.objective,
        prior_tool_result,
    )
    .await?;
    // Dispatch-only metadata distinguishes tool turns without changing the
    // persisted semantic request or storing transient tool results there.
    if let Some(object) = body.as_object_mut() {
        object.insert("turnSequence".to_owned(), json!(turn.turn_sequence));
        object.insert(
            "priorTranscriptSha256".to_owned(),
            json!(turn.prior_transcript_sha256),
        );
    }
    // The provider receives the immutable snapshot UUID with its stored hash.
    let input_snapshot_id = resolve_snapshot_id_for_dispatch(context.state, turn).await?;
    let (body, request_sha256) = if context.provider == RELAY_PROVIDER {
        validate_relay_target(context.target, RELAY_CHAT_PATH)?;
        let request = relay_chat_request(
            context.agent_type,
            context.model,
            &body,
            turn,
            input_snapshot_id,
            context.run_id,
            context.provider_config_id,
            context.semantic_request_sha256,
        )?;
        (request.body, request.request_sha256)
    } else {
        (body, turn.request_sha256.clone())
    };
    Ok(PreparedProviderRequest {
        body,
        request_sha256,
        input_snapshot_id,
    })
}

async fn send_provider_request(
    context: &ProviderRequestContext<'_>,
    turn: &ProviderTurnIdentity,
    prior_tool_result: Option<&Value>,
) -> Result<ProviderDispatchResponse, Failure> {
    let request = prepare_provider_request(context, turn, prior_tool_result).await?;
    let response = context
        .state
        .client
        .post(context.gateway.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-ai-provider", context.provider)
        .header("x-gurine-egress-target", context.target)
        .header("x-gurine-ai-agent-run-id", context.run_id.to_string())
        .header(
            "x-gurine-ai-input-snapshot-id",
            request.input_snapshot_id.to_string(),
        )
        .header(
            "x-gurine-ai-input-snapshot-sha256",
            turn.input_snapshot_sha256.as_str(),
        )
        .header("x-gurine-ai-provider-turn-id", turn.turn_id.to_string())
        .header("x-gurine-ai-agent-type", context.agent_type)
        .header(
            "x-gurine-ai-provider-config-id",
            context.provider_config_id.to_string(),
        )
        .header("x-gurine-ai-model-id", context.model)
        .header(
            "x-gurine-ai-model-configuration-sha256",
            sha256(context.model.as_bytes()),
        )
        .header(
            "x-gurine-ai-idempotency-key-sha256",
            turn.idempotency_hash.as_str(),
        )
        .header(
            "x-gurine-source-fetch-request-sha256",
            request.request_sha256.as_str(),
        )
        .header("x-gurine-idempotency-key", turn.idempotency_hash.as_str())
        .json(&request.body)
        .send()
        .await;
    match response {
        Ok(response) => Ok(ProviderDispatchResponse {
            response,
            request_sha256: request.request_sha256,
        }),
        Err(error) => {
            let detail = error.to_string();
            Err(unresolved_provider_outcome(detail))
        }
    }
}

async fn finalize_provider_response(
    request: &ProviderRequestContext<'_>,
    response: ProviderDispatchResponse,
    turn: &ProviderTurnIdentity,
    maximum_cost_krw: i64,
    pricing: &LocalPricing,
    relay_data_policy: Option<&RelayDataPolicy>,
) -> Result<(Option<Value>, i64, Option<String>, Option<Value>), Failure> {
    let context = ProviderResponseContext {
        state: request.state,
        turn,
        run_id: request.run_id,
        provider_config_id: request.provider_config_id,
        provider: request.provider,
        model: request.model,
        semantic_request_sha256: request.semantic_request_sha256,
    };
    let body = provider_response_body(
        &context,
        response,
        relay_data_policy,
        pricing,
        request.evidence,
        maximum_cost_krw,
        request.agent_type,
    )
    .await?;
    let (receipt, receipt_id, accepted_tool_call) =
        accepted_provider_receipt(&context, &body).await?;
    let output = body.get("output").cloned().unwrap_or_else(|| body.clone());
    let actual_cost = bounded_provider_cost(&context, &receipt, pricing, maximum_cost_krw).await?;
    if accepted_tool_call {
        return persist_tool_turn(
            request.state,
            turn,
            request.agent_type,
            &body,
            request.evidence,
            &receipt,
            receipt_id,
            actual_cost,
        )
        .await;
    }
    persist_validated_output(
        &context,
        request.agent_type,
        &output,
        &receipt,
        receipt_id,
        actual_cost,
    )
    .await
}

async fn accepted_provider_receipt(
    context: &ProviderResponseContext<'_>,
    body: &Value,
) -> Result<(Value, Uuid, bool), Failure> {
    let Some(receipt) = body
        .get("providerReceipt")
        .or_else(|| body.get("receipt"))
        .cloned()
    else {
        let provider_code = body
            .get("code")
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN_PROVIDER_ERROR");
        return context
            .reject_unresolved(
                "provider receipt missing",
                format!("{}:{}", context.turn.turn_id, provider_code),
            )
            .await;
    };
    let receipt_id = bound_receipt_id(context, &receipt).await?;
    let outcome = receipt.get("outcome").and_then(Value::as_str).unwrap_or("");
    let accepted_tool_call = outcome == "ACCEPTED_TOOL_CALL";
    if outcome == "ACCEPTED_FINAL" || accepted_tool_call {
        return Ok((receipt, receipt_id, accepted_tool_call));
    }
    let code = match provider_failure_code(outcome) {
        Ok(code) => code,
        Err(_) => {
            return context
                .reject_unresolved(
                    "provider outcome unrecognized",
                    context.turn.turn_id.to_string(),
                )
                .await;
        }
    };
    complete_provider_turn_failure(context.state, context.turn, &receipt, receipt_id, code).await?;
    if code == "PROVIDER_OUTCOME_UNKNOWN" {
        context
            .reject_unresolved(code, context.turn.turn_id.to_string())
            .await
    } else {
        Err(Failure::Terminal(code, context.turn.turn_id.to_string()))
    }
}

async fn bounded_provider_cost(
    context: &ProviderResponseContext<'_>,
    receipt: &Value,
    pricing: &LocalPricing,
    maximum_cost_krw: i64,
) -> Result<i64, Failure> {
    let actual_cost = match receipt_cost_krw(receipt, pricing) {
        Ok(cost) => cost,
        Err(_) => {
            return context
                .reject_unresolved("provider pricing invalid", context.turn.turn_id.to_string())
                .await;
        }
    };
    if actual_cost < 0 || actual_cost > maximum_cost_krw {
        return context
            .reject_unresolved("provider cost exceeds budget", context.provider.to_owned())
            .await;
    }
    Ok(actual_cost)
}

async fn persist_validated_output(
    context: &ProviderResponseContext<'_>,
    agent_type: &str,
    output: &Value,
    receipt: &Value,
    receipt_id: Uuid,
    actual_cost: i64,
) -> Result<(Option<Value>, i64, Option<String>, Option<Value>), Failure> {
    if validate_agent_output_for(Some(agent_type), output).is_err() {
        insert_output_validation_failure(
            context.state,
            context.turn,
            output,
            "OUTPUT_SCHEMA_INVALID",
            "provider output did not satisfy the selected agent schema",
        )
        .await?;
        let mut failure_receipt = receipt.clone();
        if let Some(object) = failure_receipt.as_object_mut() {
            object.insert(
                "outcome".to_owned(),
                Value::String("DEFINITIVE_REJECTED".to_owned()),
            );
            object.insert(
                "proofKind".to_owned(),
                Value::String("VALIDATED_OUTPUT_REJECTION".to_owned()),
            );
            object.insert(
                "proofSha256".to_owned(),
                Value::String(sha256(b"OUTPUT_SCHEMA_INVALID")),
            );
            object.remove("receiptSha256");
        }
        let failure_receipt_sha = sha256(&canonical_bytes(&failure_receipt)?);
        failure_receipt["receiptSha256"] = Value::String(failure_receipt_sha);
        complete_provider_turn_failure(
            context.state,
            context.turn,
            &failure_receipt,
            receipt_id,
            "PROVIDER_RESPONSE_INVALID",
        )
        .await?;
        return Err(Failure::Terminal(
            "PROVIDER_RESPONSE_INVALID",
            context.turn.turn_id.to_string(),
        ));
    }
    complete_provider_turn(
        context.state,
        context.turn,
        receipt,
        receipt_id,
        output,
        actual_cost,
    )
    .await?;
    Ok((Some(output.clone()), actual_cost, None, None))
}

#[expect(
    clippy::too_many_arguments,
    reason = "provider tool turn binds receipt, snapshot, and immutable tool transcript"
)]
async fn persist_tool_turn(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    body: &Value,
    evidence: &Value,
    receipt: &Value,
    receipt_id: Uuid,
    actual_cost: i64,
) -> Result<(Option<Value>, i64, Option<String>, Option<Value>), Failure> {
    let call = parse_tool_call(state, body, turn, evidence).await?;
    let (tool_result, transcript_sha256) =
        dispatch_tool_call(state, turn, agent_type, call.clone(), receipt, receipt_id).await?;
    complete_provider_turn_tool_call(
        state,
        turn,
        receipt,
        receipt_id,
        &call,
        &tool_result,
        transcript_sha256.as_str(),
        actual_cost,
    )
    .await?;
    Ok((
        None,
        actual_cost,
        Some(transcript_sha256),
        Some(tool_result),
    ))
}

async fn bound_receipt_id(
    context: &ProviderResponseContext<'_>,
    receipt: &Value,
) -> Result<Uuid, Failure> {
    match validate_provider_receipt(
        receipt,
        context.run_id,
        context.turn.turn_id,
        context.provider_config_id,
        context.provider,
        context.model,
        context.semantic_request_sha256,
        &context.turn.idempotency_hash,
    ) {
        Ok(id) => Ok(id),
        Err(_) => {
            context
                .reject_unresolved(
                    "provider receipt binding invalid",
                    context.turn.turn_id.to_string(),
                )
                .await
        }
    }
}

struct ProviderResponseContext<'a> {
    state: &'a State,
    turn: &'a ProviderTurnIdentity,
    run_id: Uuid,
    provider_config_id: Uuid,
    provider: &'a str,
    model: &'a str,
    semantic_request_sha256: &'a str,
}

impl ProviderResponseContext<'_> {
    async fn reject_unresolved<T>(
        &self,
        reason: &str,
        detail: impl Into<String>,
    ) -> Result<T, Failure> {
        let detail_text = detail.into();
        let detail_sha256 = sha256(detail_text.as_bytes());
        tracing::warn!(
            provider_turn_id=%self.turn.turn_id,
            reason,
            detail_sha256,
            detail_redacted=true,
            "provider response rejected"
        );
        Err(unresolved_provider_outcome(detail_text))
    }
}
