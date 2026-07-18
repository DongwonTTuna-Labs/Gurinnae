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
    let rows = sqlx::query(
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
        "responseFormat": "gurine-agent-output-v1",
    });
    redact_provider_payload(&mut semantic_request);
    let semantic_request_sha256 = sha256(&canonical_bytes(&semantic_request)?);
    for requested in &state.config.provider_order {
        let Some(row) = rows.iter().find(|row| {
            row.try_get::<String, _>("provider_type")
                .is_ok_and(|value| value.eq_ignore_ascii_case(requested))
                || row
                    .try_get::<String, _>("name")
                    .is_ok_and(|value| value.eq_ignore_ascii_case(requested))
        }) else {
            continue;
        };
        let provider: String = row.try_get("provider_type").map_err(database)?;
        let provider_config_id: Uuid = row.try_get("id").map_err(database)?;
        let routing: Value = row.try_get("routing_policy").map_err(database)?;
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
        let routing_version: i64 = row.try_get("version").map_err(database)?;
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
        blocked_output("ABSTAINED", "PROVIDER_UNAVAILABLE"),
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
    let mut prior_transcript_sha256 = sha256(b"{\"calls\":[]}");
    let mut prior_tool_result: Option<Value> = None;
    let mut total_cost = 0_i64;
    for turn_sequence in 1..=16_i32 {
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
            model, target, agent_type, semantic_request_sha256,
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
        blocked_output("ABSTAINED", "ITERATION_LIMIT_REACHED"),
        total_cost,
    )))
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
    semantic_request_sha256: &str,
) -> Result<reqwest::Response, Failure> {
    let wire_request = provider_wire_request(
        &turn.request_redacted,
        evidence,
        state.object_store.as_ref(),
    )
    .await?;
    let response = state.client.post(gateway.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-ai-provider", provider)
        .header("x-gurine-egress-target", target)
        .header("x-gurine-ai-agent-run-id", run_id.to_string())
        .header("x-gurine-ai-provider-turn-id", turn.turn_id.to_string())
        .header("x-gurine-ai-agent-type", agent_type)
        .header("x-gurine-ai-provider-config-id", provider_config_id.to_string())
        .header("x-gurine-ai-model-id", model)
        .header("x-gurine-ai-model-configuration-sha256", sha256(model.as_bytes()))
        .header("x-gurine-ai-idempotency-key-sha256", turn.idempotency_hash.as_str())
        .header("x-gurine-idempotency-key", turn.idempotency_hash.as_str())
        .json(&wire_request).send().await;
    match response {
        Ok(response) => Ok(response),
        Err(error) => {
            let detail = error.to_string();
            mark_provider_turn_outcome_unknown(
                state, turn, run_id, provider_config_id, provider, model,
                semantic_request_sha256, &detail,
            ).await?;
            Err(Failure::Retryable("PROVIDER_OUTCOME_UNKNOWN", detail))
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "response validation binds receipt, budget, and request digests"
)]
async fn finalize_provider_response(
    state: &State,
    response: reqwest::Response,
    turn: &ProviderTurnIdentity,
    run_id: Uuid,
    provider_config_id: Uuid,
    provider: &str,
    model: &str,
    semantic_request_sha256: &str,
    maximum_cost_krw: i64,
    pricing: &LocalPricing,
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
    let body: Value = match response.json().await {
        Ok(body) => body,
        Err(error) => {
            return context.retry_unknown(&error.to_string(), turn.turn_id.to_string()).await.map(|_| retry_result_shape());
        }
    };
    let receipt = match body
        .get("providerReceipt")
        .or_else(|| body.get("receipt"))
        .cloned()
    {
        Some(receipt) => receipt,
        None => {
            return context.retry_unknown("provider receipt missing", turn.turn_id.to_string()).await.map(|_| retry_result_shape());
        }
    };
    let receipt_id = bound_receipt_id(&context, &receipt).await?;
    let outcome = receipt.get("outcome").and_then(Value::as_str).unwrap_or("");
    if !matches!(outcome, "ACCEPTED_FINAL" | "ACCEPTED_TOOL_CALL") {
        let code = match provider_failure_code(outcome) {
            Ok(code) => code,
            Err(_) => {
                return context.retry_unknown("provider outcome unrecognized", turn.turn_id.to_string()).await.map(|_| retry_result_shape());
            }
        };
        complete_provider_turn_failure(state, turn, &receipt, receipt_id, code).await?;
        return if code == "PROVIDER_OUTCOME_UNKNOWN" {
            Err(Failure::Retryable(code, turn.turn_id.to_string()))
        } else {
            Err(Failure::Terminal(code, turn.turn_id.to_string()))
        };
    }
    let output = body.get("output").cloned().unwrap_or_else(|| body.clone());
    let actual_cost = match receipt_cost_krw(&receipt, pricing) {
        Ok(cost) => cost,
        Err(_) => {
            return context.retry_unknown("provider pricing invalid", turn.turn_id.to_string()).await.map(|_| retry_result_shape());
        }
    };
    if actual_cost < 0 || actual_cost > maximum_cost_krw {
        return context.retry_unknown("provider cost exceeds budget", provider.to_owned()).await.map(|_| retry_result_shape());
    }
    if outcome == "ACCEPTED_TOOL_CALL" {
        let call = parse_tool_call(&body, turn, evidence)?;
        let (tool_result, transcript_sha256) = dispatch_tool_call(
            state,
            turn,
            agent_type,
            call.clone(),
            &receipt,
        )
        .await?;
        complete_provider_turn_tool_call(
            state,
            turn,
            &receipt,
            receipt_id,
            &call,
            &tool_result,
            transcript_sha256.as_str(),
            actual_cost,
        )
        .await?;
        return Ok((None, actual_cost, Some(transcript_sha256), Some(tool_result)));
    }
    if validate_agent_output(&output).is_err() {
        return context.retry_unknown("provider output schema invalid", turn.turn_id.to_string()).await.map(|_| retry_result_shape());
    }
    complete_provider_turn(state, turn, &receipt, receipt_id, &output, actual_cost).await?;
    Ok((Some(output), actual_cost, None, None))
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
            .retry_unknown("provider receipt binding invalid", context.turn.turn_id.to_string())
            .await
            .map(|_| Uuid::nil()),
    }
}

fn retry_result_shape() -> (Option<Value>, i64, Option<String>, Option<Value>) {
    (None, 0, None, None)
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
    async fn retry_unknown(
        &self,
        reason: &str,
        detail: impl Into<String>,
    ) -> Result<Option<(Value, i64)>, Failure> {
        let detail_text = detail.into();
        tracing::warn!(provider_turn_id=%self.turn.turn_id, reason, detail=%detail_text, "provider response rejected");
        mark_provider_turn_outcome_unknown(
            self.state,
            self.turn,
            self.run_id,
            self.provider_config_id,
            self.provider,
            self.model,
            self.semantic_request_sha256,
            reason,
        )
        .await?;
        Err(Failure::Retryable(
            "PROVIDER_OUTCOME_UNKNOWN",
            detail_text,
        ))
    }
}

/// The pricing schedule is activated with the provider routing policy and is
/// copied into the budget reservation as `provider-pricing-v1`. Provider
/// reported prices are evidence only: the worker recomputes the settled
/// amount from this immutable local schedule and rejects a receipt whose
/// arithmetic or schedule digest differs.
struct LocalPricing {
    version: String,
    digest: String,
    input_micros_per_unit: i64,
    output_micros_per_unit: i64,
}

impl LocalPricing {
    fn from_routing_policy(policy: &Value) -> Result<Self, Failure> {
        let value = policy
            .get("pricing")
            .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_UNAVAILABLE", "pricing".into()))?;
        let object = value
            .as_object()
            .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_INVALID", "object".into()))?;
        let version = required_text(object, "pricingVersion")?;
        let digest = required_hash(object, "pricingSha256")?;
        let input_micros_per_unit = required_positive_i64(object, "inputMicrosKrwPerUnit")?;
        let output_micros_per_unit = required_positive_i64(object, "outputMicrosKrwPerUnit")?;
        let canonical = json!({
            "currency": "KRW",
            "inputMicrosKrwPerUnit": input_micros_per_unit,
            "outputMicrosKrwPerUnit": output_micros_per_unit,
            "pricingVersion": version,
        });
        if sha256(&canonical_bytes(&canonical)?) != digest {
            return Err(Failure::Terminal(
                "PROVIDER_PRICING_INVALID",
                "pricingSha256".into(),
            ));
        }
        Ok(Self {
            version,
            digest,
            input_micros_per_unit,
            output_micros_per_unit,
        })
    }
}

fn required_text(object: &serde_json::Map<String, Value>, key: &str) -> Result<String, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty() && value.chars().count() <= 64)
        .map(str::to_owned)
        .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_INVALID", key.into()))
}

fn required_hash(object: &serde_json::Map<String, Value>, key: &str) -> Result<String, Failure> {
    let value = required_text(object, key)?;
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(Failure::Terminal("PROVIDER_PRICING_INVALID", key.into()));
    }
    Ok(value)
}

fn required_positive_i64(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<i64, Failure> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_INVALID", key.into()))
}

fn provider_failure_code(outcome: &str) -> Result<&'static str, Failure> {
    match outcome {
        "DEFINITIVE_REJECTED" => Ok("PROVIDER_REJECTED"),
        "RATE_LIMITED" => Ok("PROVIDER_RATE_LIMITED"),
        "TIMED_OUT_BEFORE_SEND" => Ok("PROVIDER_TIMEOUT"),
        "OUTCOME_UNKNOWN" => Ok("PROVIDER_OUTCOME_UNKNOWN"),
        "CANCELLED_CONFIRMED" | "NO_DISPATCH_CONFIRMED" => Ok("PROVIDER_CANCELLED"),
        _ => Err(Failure::Retryable(
            "PROVIDER_OUTCOME_UNKNOWN",
            "unrecognized receipt outcome".into(),
        )),
    }
}

struct ProviderTurnIdentity {
    turn_id: Uuid,
    run_id: Uuid,
    idempotency_hash: String,
    request_redacted: Value,
    input_snapshot_sha256: String,
    prior_transcript_sha256: String,
    provider_config_id: Uuid,
    provider_mode: String,
    provider_candidate_id: String,
    model_id: String,
    model_configuration_sha256: String,
    routing_policy_version: String,
    routing_decision_sha256: String,
    prompt_id: String,
    prompt_version: String,
    prompt_sha256: String,
    output_schema_id: String,
    output_schema_version: String,
    output_schema_sha256: String,
    classification: String,
    model_use_rights_sha256: String,
    budget_reservation_key_sha256: String,
    dispatch_key_sha256: String,
    request_sha256: String,
    turn_sequence: i32,
    attempt_sequence: i32,
    dispatched_at: String,
}

fn redact_provider_payload(value: &mut Value) {
    if let Some(object) = value.as_object_mut() {
        // Evidence is a typed digest/locator graph, not raw source text. Keep
        // its exact hashes and source-use identities in the semantic request;
        // redacting those values would make the provider unable to bind the
        // request to the selected bytes. Only free-form instructions pass
        // through the generic secret redactor.
        if let Some(objective) = object.get_mut("objective") {
            gurine_observability::redaction::redact(objective);
        }
    }
}

fn parse_receipt_uuid(object: &serde_json::Map<String, Value>, key: &str) -> Result<Uuid, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("PROVIDER_RECEIPT_INVALID", key.into()))
}

fn receipt_cost_krw(receipt: &Value, pricing: &LocalPricing) -> Result<i64, Failure> {
    if !matches!(
        receipt.get("outcome").and_then(Value::as_str),
        Some("ACCEPTED_FINAL" | "ACCEPTED_TOOL_CALL")
    ) {
        return Err(Failure::Terminal(
            "PROVIDER_RESPONSE_INVALID",
            "final outcome required".into(),
        ));
    }
    if receipt
        .pointer("/pricing/costState")
        .and_then(Value::as_str)
        != Some("SETTLED")
    {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "settled pricing required".into(),
        ));
    }
    let pricing_object = receipt
        .get("pricing")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "pricing".into()))?;
    if pricing_object.get("pricingVersion").and_then(Value::as_str) != Some(pricing.version.as_str())
        || pricing_object.get("pricingSha256").and_then(Value::as_str) != Some(pricing.digest.as_str())
    {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "local pricing binding".into(),
        ));
    }
    let usage = receipt
        .get("usage")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "usage".into()))?;
    let input_units = usage
        .get("inputUnits")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "inputUnits".into()))?;
    let output_units = usage
        .get("outputUnits")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "outputUnits".into()))?;
    if input_units < 0 || output_units < 0 {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "negative usage".into(),
        ));
    }
    let calculated_micros = input_units
        .checked_mul(pricing.input_micros_per_unit)
        .and_then(|value| {
            output_units
                .checked_mul(pricing.output_micros_per_unit)
                .and_then(|output| value.checked_add(output))
        })
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "overflow".into()))?;
    let micros = pricing_object
        .get("actualMicrosKrw")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "actualMicrosKrw".into()))?;
    if micros < 0 || micros != calculated_micros {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "provider cost does not match local schedule".into(),
        ));
    }
    micros
        .checked_add(999_999)
        .and_then(|value| value.checked_div(1_000_000))
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "overflow".into()))
}
