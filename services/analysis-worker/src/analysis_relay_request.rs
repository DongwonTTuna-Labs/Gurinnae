use super::*;

#[expect(
    clippy::too_many_arguments,
    reason = "relay user content binds every immutable provider turn identity"
)]
pub(super) fn relay_chat_request(
    agent_type: &str,
    model: &str,
    internal_wire_request: &Value,
    turn: &ProviderTurnIdentity,
    input_snapshot_id: Uuid,
    run_id: Uuid,
    provider_config_id: Uuid,
    semantic_request_sha256: &str,
) -> Result<RelayWireRequest, Failure> {
    let wire = internal_wire_request
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_REQUEST_INVALID", "object".into()))?;
    let objective = wire
        .get("objective")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_REQUEST_INVALID", "objective".into()))?;
    let selected_refs = wire
        .get("selectedContentRefs")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("PROVIDER_REQUEST_INVALID", "selectedContentRefs".into()))?;
    let user = json!({
        "bindings": {
            "agentRunId": run_id,
            "agentType": agent_type,
            "idempotencyKeySha256": turn.idempotency_hash,
            "inputSnapshotId": input_snapshot_id,
            "inputSnapshotSha256": turn.input_snapshot_sha256,
            "priorTranscriptSha256": turn.prior_transcript_sha256,
            "providerConfigId": provider_config_id,
            "providerTurnId": turn.turn_id,
            "semanticRequestSha256": semantic_request_sha256,
            "turnSequence": turn.turn_sequence,
        },
        "objective": objective,
        "priorToolResult": wire.get("priorToolResult").cloned().unwrap_or(Value::Null),
        "selectedContentRefs": selected_refs,
    });
    let user_content = String::from_utf8(canonical_bytes(&user)?)
        .map_err(|error| Failure::Terminal("PROVIDER_REQUEST_INVALID", error.to_string()))?;
    let prompt = pinned_prompt_bytes(agent_type)
        .ok_or_else(|| Failure::Terminal("AGENT_REGISTRY_DRIFT", agent_type.to_owned()))?;
    let max_output_units = wire
        .get("maxOutputUnits")
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| Failure::Terminal("PROVIDER_REQUEST_INVALID", "maxOutputUnits".into()))?;
    let body = json!({
        "max_completion_tokens": max_output_units,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": user_content},
        ],
        "model": model,
        "response_format": {"type": "json_object"},
        "tool_choice": "auto",
        "tools": relay_tools(agent_type)?,
    });
    let request_sha256 = sha256(&canonical_bytes(&body)?);
    Ok(RelayWireRequest {
        body,
        request_sha256,
    })
}

fn pinned_prompt_bytes(agent_type: &str) -> Option<&'static str> {
    match agent_type {
        "market-researcher" => Some(include_str!(
            "../../../specs/agents/market-researcher/prompt.md"
        )),
        "investigator" => Some(include_str!(
            "../../../specs/agents/investigator/prompt.md"
        )),
        "skeptic" => Some(include_str!("../../../specs/agents/skeptic/prompt.md")),
        "claim-drafter" => Some(include_str!(
            "../../../specs/agents/claim-drafter/prompt.md"
        )),
        "citation-verifier" => Some(include_str!(
            "../../../specs/agents/citation-verifier/prompt.md"
        )),
        _ => None,
    }
}

fn relay_tools(agent_type: &str) -> Result<Vec<Value>, Failure> {
    relay_allowed_tool_ids(agent_type)
        .iter()
        .map(|tool_id| {
            Ok(json!({
                "type": "function",
                "function": {
                    "name": relay_tool_name(tool_id).ok_or_else(|| {
                        Failure::Terminal("AGENT_REGISTRY_DRIFT", (*tool_id).to_owned())
                    })?,
                    "parameters": relay_tool_schema(tool_id).ok_or_else(|| {
                        Failure::Terminal("AGENT_REGISTRY_DRIFT", (*tool_id).to_owned())
                    })?,
                    "strict": true,
                }
            }))
        })
        .collect()
}

pub(super) fn relay_allowed_tool_ids(agent_type: &str) -> &'static [&'static str] {
    match agent_type {
        "market-researcher" => &[
            "evidence.search",
            "source.fetch",
            "contract.find_comparables",
        ],
        "investigator" => &[
            "evidence.search",
            "evidence.read",
            "contract.find_comparables",
            "entity.lookup",
        ],
        "skeptic" => &["evidence.search", "evidence.read", "rule.reproduce"],
        "claim-drafter" => &["evidence.read", "response.read", "claim.language_check"],
        "citation-verifier" => &["evidence.read", "source.locator_verify"],
        _ => &[],
    }
}

fn relay_tool_name(tool_id: &str) -> Option<&'static str> {
    relay_tool_row(tool_id).map(|row| row.1)
}

pub(super) fn relay_tool_id(name: &str) -> Option<&'static str> {
    RELAY_TOOL_ROWS
        .iter()
        .find(|row| row.1 == name)
        .map(|row| row.0)
}

fn relay_tool_schema(tool_id: &str) -> Option<Value> {
    relay_tool_row(tool_id).and_then(|row| serde_json::from_str(row.2).ok())
}

fn relay_tool_row(tool_id: &str) -> Option<&'static (&'static str, &'static str, &'static str)> {
    RELAY_TOOL_ROWS.iter().find(|row| row.0 == tool_id)
}

const RELAY_TOOL_ROWS: &[(&str, &str, &str)] = &[
    ("claim.language_check", "claim__dot__language_check", include_str!("../../../specs/agents/addendum-v2/tools/claim-language-check.request.schema.json")),
    ("contract.find_comparables", "contract__dot__find_comparables", include_str!("../../../specs/agents/addendum-v2/tools/contract-find-comparables.request.schema.json")),
    ("entity.lookup", "entity__dot__lookup", include_str!("../../../specs/agents/addendum-v2/tools/entity-lookup.request.schema.json")),
    ("evidence.read", "evidence__dot__read", include_str!("../../../specs/agents/addendum-v2/tools/evidence-read.request.schema.json")),
    ("evidence.search", "evidence__dot__search", include_str!("../../../specs/agents/addendum-v2/tools/evidence-search.request.schema.json")),
    ("response.read", "response__dot__read", include_str!("../../../specs/agents/addendum-v2/tools/response-read.request.schema.json")),
    ("rule.reproduce", "rule__dot__reproduce", include_str!("../../../specs/agents/addendum-v2/tools/rule-reproduce.request.schema.json")),
    ("source.fetch", "source__dot__fetch", include_str!("../../../specs/agents/addendum-v2/tools/source-fetch.request.schema.json")),
    ("source.locator_verify", "source__dot__locator_verify", include_str!("../../../specs/agents/addendum-v2/tools/source-locator-verify.request.schema.json")),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_tool_names_are_closed_and_reversible() {
        for row in RELAY_TOOL_ROWS {
            assert_eq!(relay_tool_id(row.1), Some(row.0));
            assert_eq!(relay_tool_name(row.0), Some(row.1));
        }
        assert_eq!(relay_tool_id("unknown__dot__tool"), None);
    }

    #[test]
    fn relay_user_binding_includes_agent_type() {
        let turn = provider_turn();
        let request = relay_chat_request(
            "investigator",
            "relay-model-v1",
            &json!({
                "maxOutputUnits": 128,
                "objective": "검증",
                "selectedContentRefs": [],
            }),
            &turn,
            Uuid::from_u128(2),
            Uuid::from_u128(3),
            Uuid::from_u128(4),
            &sha256(b"semantic"),
        )
        .expect("relay request");
        let user_content = request.body["messages"][1]["content"]
            .as_str()
            .expect("user content");
        let user: Value = serde_json::from_str(user_content).expect("canonical user JSON");
        assert_eq!(user["bindings"]["agentType"], "investigator");
    }

    fn provider_turn() -> ProviderTurnIdentity {
        ProviderTurnIdentity {
            turn_id: Uuid::from_u128(1),
            run_id: Uuid::from_u128(3),
            idempotency_hash: sha256(b"idempotency"),
            request_redacted: json!({}),
            input_snapshot_sha256: sha256(b"snapshot"),
            prior_transcript_sha256: sha256(b"transcript"),
            provider_config_id: Uuid::from_u128(4),
            provider_mode: "EXTERNAL_APPROVED".to_owned(),
            provider_candidate_id: RELAY_PROVIDER.to_owned(),
            model_id: "relay-model-v1".to_owned(),
            model_configuration_sha256: sha256(b"relay-model-v1"),
            routing_policy_version: "1".to_owned(),
            routing_decision_sha256: sha256(b"routing"),
            prompt_id: "investigator".to_owned(),
            prompt_version: "v1".to_owned(),
            prompt_sha256: sha256(b"prompt"),
            output_schema_id: "investigator-output".to_owned(),
            output_schema_version: "v2".to_owned(),
            output_schema_sha256: sha256(b"schema"),
            classification: "INTERNAL".to_owned(),
            model_use_rights_sha256: sha256(b"rights"),
            budget_reservation_key_sha256: sha256(b"budget"),
            dispatch_key_sha256: sha256(b"dispatch"),
            request_sha256: sha256(b"request"),
            turn_sequence: 1,
            attempt_sequence: 1,
            dispatched_at: "2026-07-29T00:00:00Z".to_owned(),
        }
    }
}
