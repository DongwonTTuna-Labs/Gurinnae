use reqwest::header::HeaderMap;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use super::*;
use super::analysis_relay_request::{relay_allowed_tool_ids, relay_tool_id};

#[derive(Clone, Debug)]
pub(super) struct RelayUsage {
    pub(super) input_units: i64,
    pub(super) output_units: i64,
    pub(super) cached_input_units: Option<i64>,
    pub(super) billable_units: i64,
    pub(super) evidence_sha256: String,
}

#[derive(Debug)]
pub(super) enum RelayEnvelope {
    Final(Value),
    Tool(Value),
}

#[derive(Debug)]
pub(super) struct RelayCompletion {
    pub(super) request_id_hash: String,
    pub(super) usage: RelayUsage,
    pub(super) envelope: RelayEnvelope,
}

pub(super) fn parse_relay_completion(
    body: &Value,
    expected_model: &str,
    agent_type: &str,
) -> Result<RelayCompletion, Failure> {
    let object = body
        .as_object()
        .ok_or_else(|| relay_response_error("object"))?;
    let request_id = bounded_relay_text(object, "id", 512)?;
    if bounded_relay_text(object, "model", 255)? != expected_model {
        return Err(relay_response_error("model"));
    }
    let usage_value = object
        .get("usage")
        .ok_or_else(|| relay_response_error("usage"))?;
    let usage = parse_relay_usage(usage_value)?;
    let choices = object
        .get("choices")
        .and_then(Value::as_array)
        .filter(|choices| choices.len() == 1)
        .ok_or_else(|| relay_response_error("choices"))?;
    let choice = choices[0]
        .as_object()
        .ok_or_else(|| relay_response_error("choice"))?;
    let message = choice
        .get("message")
        .and_then(Value::as_object)
        .ok_or_else(|| relay_response_error("message"))?;
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return Err(relay_response_error("role"));
    }
    let envelope = parse_relay_envelope(choice, message, agent_type)?;
    Ok(RelayCompletion {
        request_id_hash: sha256(request_id.as_bytes()),
        usage,
        envelope,
    })
}

fn parse_relay_usage(value: &Value) -> Result<RelayUsage, Failure> {
    let usage = value
        .as_object()
        .ok_or_else(|| relay_response_error("usage object"))?;
    let input_units = nonnegative_relay_i64(usage, "prompt_tokens")?;
    let output_units = nonnegative_relay_i64(usage, "completion_tokens")?;
    let billable_units = nonnegative_relay_i64(usage, "total_tokens")?;
    let sum = input_units
        .checked_add(output_units)
        .ok_or_else(|| relay_response_error("usage overflow"))?;
    if sum != billable_units {
        return Err(relay_response_error("total_tokens"));
    }
    let cached_input_units = usage
        .get("prompt_tokens_details")
        .and_then(Value::as_object)
        .and_then(|details| details.get("cached_tokens"))
        .map(|value| {
            value
                .as_i64()
                .filter(|units| *units >= 0)
                .ok_or_else(|| relay_response_error("cached_tokens"))
        })
        .transpose()?;
    Ok(RelayUsage {
        input_units,
        output_units,
        cached_input_units,
        billable_units,
        evidence_sha256: sha256(&canonical_bytes(value)?),
    })
}

fn parse_relay_envelope(
    choice: &serde_json::Map<String, Value>,
    message: &serde_json::Map<String, Value>,
    agent_type: &str,
) -> Result<RelayEnvelope, Failure> {
    let tool_calls = message.get("tool_calls").and_then(Value::as_array);
    if let Some(calls) = tool_calls.filter(|calls| !calls.is_empty()) {
        if calls.len() != 1
            || choice.get("finish_reason").and_then(Value::as_str) != Some("tool_calls")
            || message
                .get("content")
                .is_some_and(|value| !value.is_null() && value.as_str().is_none_or(str::is_empty))
        {
            return Err(relay_response_error("tool_calls"));
        }
        return Ok(RelayEnvelope::Tool(parse_relay_tool_call(
            &calls[0], agent_type,
        )?));
    }
    if choice.get("finish_reason").and_then(Value::as_str) != Some("stop") {
        return Err(relay_response_error("finish_reason"));
    }
    let content = message
        .get("content")
        .and_then(Value::as_str)
        .ok_or_else(|| relay_response_error("content"))?;
    let output = serde_json::from_str::<Value>(content)
        .map_err(|error| relay_response_error(format!("content:{error}")))?;
    if !output.is_object() {
        return Err(relay_response_error("content object"));
    }
    Ok(RelayEnvelope::Final(output))
}

fn parse_relay_tool_call(value: &Value, agent_type: &str) -> Result<Value, Failure> {
    let call = value
        .as_object()
        .ok_or_else(|| relay_response_error("tool call"))?;
    if call.get("type").and_then(Value::as_str) != Some("function") {
        return Err(relay_response_error("tool type"));
    }
    let call_id = bounded_relay_text(call, "id", 64)?;
    let function = call
        .get("function")
        .and_then(Value::as_object)
        .ok_or_else(|| relay_response_error("function"))?;
    let name = bounded_relay_text(function, "name", 64)?;
    let tool_id = relay_tool_id(&name).ok_or_else(|| relay_response_error("tool name"))?;
    if !relay_allowed_tool_ids(agent_type).contains(&tool_id) {
        return Err(relay_response_error("tool allowlist"));
    }
    let arguments_text = bounded_relay_text(function, "arguments", 262_144)?;
    let arguments = serde_json::from_str::<Value>(&arguments_text)
        .map_err(|error| relay_response_error(format!("arguments:{error}")))?;
    if !arguments.is_object() {
        return Err(relay_response_error("arguments object"));
    }
    let request_sha256 = sha256(&canonical_bytes(&arguments)?);
    Ok(json!({
        "callId": call_id,
        "request": arguments,
        "requestSha256": request_sha256,
        "toolId": tool_id,
    }))
}

pub(super) fn bounded_relay_text(
    object: &serde_json::Map<String, Value>,
    key: &str,
    maximum: usize,
) -> Result<String, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= maximum)
        .map(str::to_owned)
        .ok_or_else(|| relay_response_error(key))
}

fn nonnegative_relay_i64(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<i64, Failure> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or_else(|| relay_response_error(key))
}

pub(super) fn relay_response_error(detail: impl Into<String>) -> Failure {
    Failure::Terminal("PROVIDER_RESPONSE_INVALID", detail.into())
}

pub(super) struct RelayGatewayObservation {
    pub(super) body: Value,
    pub(super) gateway_receipt_sha256: String,
    pub(super) payload_sha256: String,
}

pub(super) async fn observe_relay_gateway_response(
    response: reqwest::Response,
    expected_request_sha256: &str,
) -> Result<RelayGatewayObservation, Failure> {
    if !response.status().is_success() {
        return Err(relay_response_error(format!(
            "http status {}",
            response.status().as_u16()
        )));
    }
    let headers = response.headers().clone();
    let gateway_receipt_sha256 = relay_hash_header(&headers, "x-gurine-egress-receipt-sha256")?;
    let expected_payload_sha256 =
        relay_hash_header(&headers, "x-gurine-source-fetch-payload-sha256")?;
    let echoed_request_sha256 =
        relay_hash_header(&headers, "x-gurine-source-fetch-request-sha256")?;
    if echoed_request_sha256 != expected_request_sha256 {
        return Err(relay_response_error("request digest mismatch"));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|error| relay_response_error(error.to_string()))?;
    let payload_sha256 = sha256(&bytes);
    if payload_sha256 != expected_payload_sha256 {
        return Err(relay_response_error("payload digest mismatch"));
    }
    let body = serde_json::from_slice(&bytes)
        .map_err(|error| relay_response_error(error.to_string()))?;
    Ok(RelayGatewayObservation {
        body,
        gateway_receipt_sha256,
        payload_sha256,
    })
}

fn relay_hash_header(headers: &HeaderMap, name: &str) -> Result<String, Failure> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .filter(|value| is_lower_sha256(value))
        .map(str::to_owned)
        .ok_or_else(|| relay_response_error(name))
}

#[expect(
    clippy::too_many_arguments,
    reason = "local receipt binds actual gateway, usage, policy, and provider identities"
)]
pub(super) fn relay_internal_response(
    observation: RelayGatewayObservation,
    expected_model: &str,
    agent_type: &str,
    turn: &ProviderTurnIdentity,
    run_id: Uuid,
    provider_config_id: Uuid,
    semantic_request_sha256: &str,
    pricing: &LocalPricing,
    data_policy: &RelayDataPolicy,
    evidence: &Value,
    maximum_cost_krw: i64,
) -> Result<Value, Failure> {
    let completion = parse_relay_completion(&observation.body, expected_model, agent_type)?;
    let rights_sha256 = bound_model_use_rights_decision_set_sha256(
        evidence,
        &turn.model_use_rights_sha256,
    )?;
    let actual_micros = relay_actual_cost_micros(&completion.usage, pricing)?;
    let reserved_micros = maximum_cost_krw
        .checked_mul(1_000_000)
        .ok_or_else(|| relay_response_error("reserved cost overflow"))?;
    let now = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|error| relay_response_error(error.to_string()))?;
    let outcome = match &completion.envelope {
        RelayEnvelope::Final(_) => "ACCEPTED_FINAL",
        RelayEnvelope::Tool(_) => "ACCEPTED_TOOL_CALL",
    };
    let mut receipt = json!({
        "schemaVersion": "provider-receipt.v2",
        "receiptId": Uuid::new_v4(),
        "agentRunId": run_id,
        "providerTurnId": turn.turn_id,
        "providerMode": "EXTERNAL_APPROVED",
        "providerConfigId": provider_config_id,
        "providerCandidateId": RELAY_PROVIDER,
        "modelId": expected_model,
        "modelConfigurationSha256": sha256(expected_model.as_bytes()),
        "semanticRequestSha256": semantic_request_sha256,
        "idempotencyKeySha256": turn.idempotency_hash,
        "outcome": outcome,
        "proofKind": "AUTHENTICATED_RESPONSE_HEADERS",
        "proofSha256": observation.gateway_receipt_sha256,
        "providerRequestIdHash": completion.request_id_hash,
        "usage": {
            "state": "PROVIDER_REPORTED",
            "inputUnits": completion.usage.input_units,
            "outputUnits": completion.usage.output_units,
            "cachedInputUnits": completion.usage.cached_input_units,
            "billableUnits": completion.usage.billable_units,
            "usageEvidenceSha256": completion.usage.evidence_sha256,
        },
        "pricing": {
            "pricingVersion": pricing.version,
            "pricingSha256": pricing.digest,
            "currency": "KRW",
            "fxRateFactId": null,
            "reservedMicrosKrw": reserved_micros,
            "actualMicrosKrw": actual_micros,
            "costState": "SETTLED",
        },
        "dataPolicy": data_policy.receipt_value(&turn.classification, &rights_sha256),
        "dispatchedAt": turn.dispatched_at,
        "observedAt": now,
        "completedAt": now,
    });
    let receipt_sha256 = sha256(&canonical_bytes(&receipt)?);
    receipt["receiptSha256"] = Value::String(receipt_sha256);
    Ok(match completion.envelope {
        RelayEnvelope::Final(output) => json!({
            "output": output,
            "providerReceipt": receipt,
            "relayPayloadSha256": observation.payload_sha256,
        }),
        RelayEnvelope::Tool(tool_call) => json!({
            "toolCall": tool_call,
            "providerReceipt": receipt,
            "relayPayloadSha256": observation.payload_sha256,
        }),
    })
}

pub(super) fn relay_actual_cost_micros(
    usage: &RelayUsage,
    pricing: &LocalPricing,
) -> Result<i64, Failure> {
    usage
        .input_units
        .checked_mul(pricing.input_micros_per_unit)
        .and_then(|input| {
            usage
                .output_units
                .checked_mul(pricing.output_micros_per_unit)
                .and_then(|output| input.checked_add(output))
        })
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "overflow".into()))
}

pub(super) fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn completion(message: Value, finish_reason: &str) -> Value {
        json!({
            "id": "chatcmpl-real-id",
            "model": "relay-model-v1",
            "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
            "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5},
        })
    }

    #[test]
    fn standard_final_content_is_strict_json() {
        let body = completion(
            json!({"role":"assistant","content":"{\"schemaVersion\":\"investigator-output.v2\"}"}),
            "stop",
        );
        let parsed = parse_relay_completion(&body, "relay-model-v1", "investigator")
            .expect("valid OpenAI completion");
        assert_eq!(parsed.request_id_hash, sha256(b"chatcmpl-real-id"));
        assert_eq!(
            parsed.usage.evidence_sha256,
            sha256(
                &canonical_bytes(&json!({
                    "prompt_tokens": 2,
                    "completion_tokens": 3,
                    "total_tokens": 5
                }))
                .expect("canonical usage"),
            ),
        );
        assert!(matches!(parsed.envelope, RelayEnvelope::Final(_)));
        let invalid = completion(
            json!({"role":"assistant","content":"```json\\n{}\\n```"}),
            "stop",
        );
        assert!(parse_relay_completion(&invalid, "relay-model-v1", "investigator").is_err());
    }

    #[test]
    fn standard_tool_call_maps_reversible_name_to_closed_tool_id() {
        let body = completion(
            json!({
                "role":"assistant",
                "content":null,
                "tool_calls":[{
                    "id":"call-real-1",
                    "type":"function",
                    "function":{
                        "name":"evidence__dot__search",
                        "arguments":"{\"query\":\"감사\"}"
                    }
                }]
            }),
            "tool_calls",
        );
        let parsed = parse_relay_completion(&body, "relay-model-v1", "investigator")
            .expect("valid OpenAI tool call");
        let RelayEnvelope::Tool(call) = parsed.envelope else {
            panic!("expected tool envelope")
        };
        assert_eq!(call["toolId"], "evidence.search");
    }

    #[test]
    fn completion_requires_provider_id_model_and_usage() {
        for missing in ["id", "model", "usage"] {
            let mut body = completion(json!({"role":"assistant","content":"{}"}), "stop");
            body.as_object_mut()
                .expect("completion object")
                .remove(missing);
            assert!(
                parse_relay_completion(&body, "relay-model-v1", "investigator").is_err(),
                "{missing} must be required"
            );
        }
    }

    #[test]
    fn gateway_receipt_header_is_required_and_lowercase_sha256() {
        let mut headers = HeaderMap::new();
        assert!(relay_hash_header(&headers, "x-gurine-egress-receipt-sha256").is_err());
        headers.insert(
            "x-gurine-egress-receipt-sha256",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                .parse()
                .expect("header"),
        );
        assert!(relay_hash_header(&headers, "x-gurine-egress-receipt-sha256").is_err());
    }

    #[test]
    fn zero_pricing_preserves_usage_and_zero_cost() {
        let pricing = LocalPricing::from_routing_policy(&json!({
            "pricing": {
                "currency":"KRW",
                "pricingVersion":"relay-unpriced-v1",
                "pricingSha256":sha256(&canonical_bytes(&json!({
                    "currency":"KRW",
                    "inputMicrosKrwPerUnit":0,
                    "outputMicrosKrwPerUnit":0,
                    "pricingVersion":"relay-unpriced-v1"
                })).expect("canonical pricing")),
                "inputMicrosKrwPerUnit":0,
                "outputMicrosKrwPerUnit":0
            }
        }))
        .expect("zero pricing is a configured schedule");
        let usage = RelayUsage {
            input_units: 12,
            output_units: 7,
            cached_input_units: None,
            billable_units: 19,
            evidence_sha256: sha256(b"usage"),
        };
        assert!(matches!(relay_actual_cost_micros(&usage, &pricing), Ok(0)));
    }

}
