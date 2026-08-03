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
        let Some((output, actual_cost)) = request_provider(
            state,
            gateway,
            run_id,
            job_id,
            case_id,
            agent_type,
            objective,
            evidence,
            maximum_cost_krw,
            &semantic_request_sha256,
            &provider,
            provider_config_id,
            target,
            &model,
            routing_version,
            input_snapshot_sha256,
            &routing,
        )
        .await?
        else {
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

#[expect(
    clippy::too_many_arguments,
    reason = "provider dispatch binds the full canonical routing and budget context"
)]
async fn request_provider(
    state: &State,
    gateway: &reqwest::Url,
    run_id: Uuid,
    job_id: Uuid,
    case_id: Uuid,
    agent_type: &str,
    objective: &str,
    evidence: &Value,
    maximum_cost_krw: i64,
    semantic_request_sha256: &str,
    provider: &str,
    provider_config_id: Uuid,
    target: &str,
    model: &str,
    routing_version: i64,
    input_snapshot_sha256: &str,
    routing_policy: &Value,
) -> Result<Option<(Value, i64)>, Failure> {
    let pricing = LocalPricing::from_routing_policy(routing_policy)?;
    let relay_data_policy = if provider == RELAY_PROVIDER {
        Some(RelayDataPolicy::from_routing_policy(routing_policy)?)
    } else {
        None
    };
    let mut prior_transcript_sha256 = sha256(b"{\"calls\":[]}");
    let mut prior_tool_result: Option<Value> = None;
    let mut total_cost = 0_i64;
    let max_provider_turns = agent_max_provider_turns(agent_type);
    for turn_sequence in 1..=max_provider_turns {
        let turn = insert_provider_turn(
            state,
            run_id,
            job_id,
            case_id,
            agent_type,
            objective,
            evidence,
            provider,
            provider_config_id,
            model,
            routing_version,
            input_snapshot_sha256,
            maximum_cost_krw.saturating_sub(total_cost),
            semantic_request_sha256,
            &state.config.environment,
            turn_sequence,
            &prior_transcript_sha256,
            prior_tool_result.as_ref(),
        )
        .await?;
        let response = send_provider_request(
            state, gateway, &turn, evidence, run_id, provider_config_id, provider,
            model, target, agent_type, objective, prior_tool_result.as_ref(), semantic_request_sha256,
        ).await?;
        let (output, cost, next_transcript, tool_result) = finalize_provider_response(
            state,
            response,
            &turn,
            run_id,
            provider_config_id,
            provider,
            model,
            semantic_request_sha256,
            maximum_cost_krw.saturating_sub(total_cost),
            &pricing,
            relay_data_policy.as_ref(),
            evidence,
            agent_type,
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
        blocked_output_for(agent_type, "ABSTAINED", "ITERATION_LIMIT_REACHED"),
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

#[expect(clippy::too_many_arguments, reason = "provider egress binds the immutable turn headers")]
async fn send_provider_request(
    state: &State,
    gateway: &reqwest::Url,
    turn: &ProviderTurnIdentity,
    evidence: &Value,
    run_id: Uuid,
    provider_config_id: Uuid,
    provider: &str,
    model: &str,
    target: &str,
    agent_type: &str,
    objective: &str,
    prior_tool_result: Option<&Value>,
    semantic_request_sha256: &str,
) -> Result<ProviderDispatchResponse, Failure> {
    // `insert_provider_turn` already persisted and hashed the exact semantic
    // request, including the selected authorized bytes.  Sending that value
    // verbatim preserves the request_sha256/wire equality contract.
    let mut wire_request = provider_wire_request(
        &turn.request_redacted,
        evidence,
        state.object_store.as_ref(),
        &state.pool,
        objective,
        prior_tool_result,
    )
    .await?;
    // Dispatch-only turn metadata is kept outside the persisted closed
    // requestRedacted object.  It lets an approved provider distinguish the
    // tool turn from the final turn without changing the semantic request
    // schema or storing transient tool results in the durable turn row.
    if let Some(object) = wire_request.as_object_mut() {
        object.insert("turnSequence".to_owned(), json!(turn.turn_sequence));
        object.insert(
            "priorTranscriptSha256".to_owned(),
            json!(turn.prior_transcript_sha256),
        );
    }
    // Tool V2 requests must carry the exact immutable snapshot binding.  The
    // provider receives the UUID alongside the already persisted hash so it
    // can emit a closed request without guessing database state.
    let input_snapshot_id = resolve_snapshot_id_for_dispatch(state, turn).await?;
    let (wire_request, request_sha256) = if provider == RELAY_PROVIDER {
        validate_relay_target(target, RELAY_CHAT_PATH)?;
        let request = relay_chat_request(
            agent_type,
            model,
            &wire_request,
            turn,
            input_snapshot_id,
            run_id,
            provider_config_id,
            semantic_request_sha256,
        )?;
        (request.body, request.request_sha256)
    } else {
        (wire_request, turn.request_sha256.clone())
    };
    let response = state.client.post(gateway.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-ai-provider", provider)
        .header("x-gurine-egress-target", target)
        .header("x-gurine-ai-agent-run-id", run_id.to_string())
        .header("x-gurine-ai-input-snapshot-id", input_snapshot_id.to_string())
        .header("x-gurine-ai-input-snapshot-sha256", turn.input_snapshot_sha256.as_str())
        .header("x-gurine-ai-provider-turn-id", turn.turn_id.to_string())
        .header("x-gurine-ai-agent-type", agent_type)
        .header("x-gurine-ai-provider-config-id", provider_config_id.to_string())
        .header("x-gurine-ai-model-id", model)
        .header("x-gurine-ai-model-configuration-sha256", sha256(model.as_bytes()))
        .header("x-gurine-ai-idempotency-key-sha256", turn.idempotency_hash.as_str())
        .header("x-gurine-source-fetch-request-sha256", request_sha256.as_str())
        .header("x-gurine-idempotency-key", turn.idempotency_hash.as_str())
        .json(&wire_request).send().await;
    match response {
        Ok(response) => Ok(ProviderDispatchResponse {
            response,
            request_sha256,
        }),
        Err(error) => {
            let detail = error.to_string();
            Err(unresolved_provider_outcome(detail))
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "response validation binds receipt, budget, and request digests"
)]
async fn finalize_provider_response(
    state: &State,
    response: ProviderDispatchResponse,
    turn: &ProviderTurnIdentity,
    run_id: Uuid,
    provider_config_id: Uuid,
    provider: &str,
    model: &str,
    semantic_request_sha256: &str,
    maximum_cost_krw: i64,
    pricing: &LocalPricing,
    relay_data_policy: Option<&RelayDataPolicy>,
    evidence: &Value,
    agent_type: &str,
) -> Result<(Option<Value>, i64, Option<String>, Option<Value>), Failure> {
    let context = ProviderResponseContext {
        state,
        turn,
        run_id,
        provider_config_id,
        provider,
        model,
        semantic_request_sha256,
    };
    let body = provider_response_body(
        &context,
        response,
        relay_data_policy,
        pricing,
        evidence,
        maximum_cost_krw,
        agent_type,
    )
    .await?;
    let Some(receipt) = body.get("providerReceipt").or_else(|| body.get("receipt")).cloned() else {
        let provider_code = body
            .get("code")
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN_PROVIDER_ERROR");
        return context
            .unresolved_shape(
                "provider receipt missing",
                format!("{}:{}", turn.turn_id, provider_code),
            )
            .await;
    };
    let receipt_id = bound_receipt_id(&context, &receipt).await?;
    let outcome = receipt.get("outcome").and_then(Value::as_str).unwrap_or("");
    if !matches!(outcome, "ACCEPTED_FINAL" | "ACCEPTED_TOOL_CALL") {
        let code = match provider_failure_code(outcome) {
            Ok(code) => code,
            Err(_) => {
                return context.unresolved_shape("provider outcome unrecognized", turn.turn_id.to_string()).await;
            }
        };
        complete_provider_turn_failure(state, turn, &receipt, receipt_id, code).await?;
        return if code == "PROVIDER_OUTCOME_UNKNOWN" {
            context.unresolved_shape(code, turn.turn_id.to_string()).await
        } else {
            Err(Failure::Terminal(code, turn.turn_id.to_string()))
        };
    }
    let output = body.get("output").cloned().unwrap_or_else(|| body.clone());
    let actual_cost = match receipt_cost_krw(&receipt, pricing) {
        Ok(cost) => cost,
        Err(_) => {
            return context.unresolved_shape("provider pricing invalid", turn.turn_id.to_string()).await;
        }
    };
    if actual_cost < 0 || actual_cost > maximum_cost_krw {
        return context.unresolved_shape("provider cost exceeds budget", provider.to_owned()).await;
    }
    if outcome == "ACCEPTED_TOOL_CALL" {
        return persist_tool_turn(state, turn, agent_type, &body, evidence, &receipt, receipt_id, actual_cost).await;
    }
    persist_validated_output(
        &context,
        agent_type,
        &output,
        &receipt,
        receipt_id,
        actual_cost,
    )
    .await
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
            object.insert("outcome".to_owned(), Value::String("DEFINITIVE_REJECTED".to_owned()));
            object.insert("proofKind".to_owned(), Value::String("VALIDATED_OUTPUT_REJECTION".to_owned()));
            object.insert("proofSha256".to_owned(), Value::String(sha256(b"OUTPUT_SCHEMA_INVALID")));
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

#[expect(clippy::too_many_arguments, reason = "provider tool turn binds receipt, snapshot, and immutable tool transcript")]
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
    let (tool_result, transcript_sha256) = dispatch_tool_call(
        state,
        turn,
        agent_type,
        call.clone(),
        receipt,
        receipt_id,
    )
    .await?;
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
    Ok((None, actual_cost, Some(transcript_sha256), Some(tool_result)))
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
        Err(_) => context
            .unresolved_binding("provider receipt binding invalid", context.turn.turn_id.to_string())
            .await
            .map(|_| Uuid::nil()),
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
        tracing::warn!(provider_turn_id=%self.turn.turn_id, reason, detail=%detail_text, "provider response rejected");
        Err(unresolved_provider_outcome(detail_text))
    }

    async fn unresolved_shape(
        &self,
        reason: &str,
        detail: impl Into<String>,
    ) -> Result<(Option<Value>, i64, Option<String>, Option<Value>), Failure> {
        self.reject_unresolved(reason, detail).await
    }

    async fn unresolved_binding(
        &self,
        reason: &str,
        detail: impl Into<String>,
    ) -> Result<Option<(Value, i64)>, Failure> {
        self.reject_unresolved(reason, detail).await
    }
}
