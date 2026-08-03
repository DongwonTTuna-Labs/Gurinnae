use super::*;
use std::collections::BTreeSet;

mod citations;
mod hypotheses;
mod proposal_persistence;

use citations::{persist_citation, resolve_citations};
use hypotheses::HypothesisMaterialization;
use proposal_persistence::persist_output_proposals;

struct PersistedValidation {
    id: Uuid,
    replayed: bool,
}

pub(super) async fn insert_output_validation(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    output: &Value,
    output_sha256: &str,
    receipt_sha256: &str,
) -> Result<(), Failure> {
    let citations = output
        .get("citations")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let citation_set_sha256 = sha256(&canonical_bytes(
        &output
            .get("citations")
            .cloned()
            .unwrap_or_else(|| json!([])),
    )?);
    let proposals = output_proposals(output)?;
    if !proposals.is_empty() && citations == 0 {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "each proposal requires at least one citation".to_owned(),
        ));
    }
    let proposal_count = i32::try_from(proposals.len())
        .map_err(|_| Failure::Terminal("AGENT_OUTPUT_INVALID", "proposal count".to_owned()))?;
    let proposal_payloads = Value::Array(
        proposals
            .iter()
            .map(|(_, payload)| payload.clone())
            .collect(),
    );
    let proposal_set_sha256 = sha256(&canonical_bytes(&proposal_payloads)?);
    let validation_sha256 = sha256(&canonical_bytes(&json!({
        "agentRunId":turn.run_id,"providerTurnId":turn.turn_id,"outputSha256":output_sha256,
        "receiptSha256":receipt_sha256,"citationSetSha256":citation_set_sha256
    }))?);
    let validated = json!({
        "status": output.get("status").or_else(|| output.get("outcome")),
        "summary": output.get("summary"),
        "citations": output.get("citations").cloned().unwrap_or_else(|| json!([]))
    });
    let validation = persist_validation(
        executor,
        turn,
        output,
        output_sha256,
        citations,
        proposal_count,
        &citation_set_sha256,
        &proposal_set_sha256,
        &validation_sha256,
        &validated,
    )
    .await?;
    persist_output_proposals(executor, turn, validation, proposals, output).await
}

#[expect(
    clippy::too_many_arguments,
    reason = "validation persistence binds output, citation, proposal, and validator digest evidence"
)]
async fn persist_validation(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    output: &Value,
    output_sha256: &str,
    citations: usize,
    proposal_count: i32,
    citation_set_sha256: &str,
    proposal_set_sha256: &str,
    validation_sha256: &str,
    validated: &Value,
) -> Result<PersistedValidation, Failure> {
    let output_status = output
        .get("status")
        .or_else(|| output.get("outcome"))
        .and_then(Value::as_str)
        .unwrap_or("COMPLETED");
    let inserted: Option<Uuid> = sqlx::query_scalar!(
        r#"INSERT INTO ops.agent_output_validations(
          agent_run_id,provider_turn_id,input_snapshot_sha256,provider_output_sha256,validator_version,validator_sha256,
          output_schema_id,output_schema_version,output_schema_sha256,validation_policy_version,validation_policy_sha256,
          validation_status,schema_status,citation_status,policy_status,run_terminal_status,output_status,failure_details_redacted,
          validated_outcome,validated_outcome_sha256,citation_count,proposal_count,citation_set_sha256,proposal_set_sha256,validation_sha256)
         VALUES($1,$2,$3,CAST($4 AS char(64)),'agent-output-validator-v2',CAST($5 AS char(64)),
          $6,$7,CAST($8 AS char(64)),'agent-output-policy-v2',CAST($9 AS char(64)),
         'VALID','PASS','PASS','PASS','SUCCEEDED',$10,'{}'::jsonb,$11,CAST($12 AS char(64)),$13,$14,CAST($15 AS char(64)),CAST($16 AS char(64)),CAST($17 AS char(64)))
         ON CONFLICT(agent_run_id,provider_turn_id) DO NOTHING RETURNING validation_id"#,
        turn.run_id,
        turn.turn_id,
        &turn.input_snapshot_sha256,
        output_sha256,
        sha256(b"agent-output-validator-v2"),
        &turn.output_schema_id,
        &turn.output_schema_version,
        &turn.output_schema_sha256,
        sha256(b"agent-output-policy-v2"),
        output_status,
        validated,
        output_sha256,
        citations as i32,
        proposal_count,
        citation_set_sha256,
        proposal_set_sha256,
        validation_sha256,
    )
    .fetch_optional(&mut *executor).await.map_err(database)?;
    if let Some(id) = inserted {
        return Ok(PersistedValidation {
            id,
            replayed: false,
        });
    }
    let id = sqlx::query_scalar!(
        r#"SELECT validation_id FROM ops.agent_output_validations
           WHERE agent_run_id=$1 AND provider_turn_id=$2
             AND input_snapshot_sha256=CAST($3 AS char(64))
             AND provider_output_sha256=CAST($4 AS char(64))
             AND validator_version='agent-output-validator-v2'
             AND validator_sha256=CAST($14 AS char(64))
             AND output_schema_id=$5 AND output_schema_version=$6
             AND output_schema_sha256=CAST($7 AS char(64))
             AND validation_policy_version='agent-output-policy-v2'
             AND validation_policy_sha256=CAST($15 AS char(64))
             AND validation_status='VALID' AND schema_status='PASS'
             AND citation_status='PASS' AND policy_status='PASS'
             AND run_terminal_status='SUCCEEDED' AND output_status=$8
             AND failure_code IS NULL AND failure_details_redacted='{}'::jsonb
             AND validated_outcome=$16
             AND validated_outcome_sha256=CAST($4 AS char(64))
             AND citation_count=$9 AND proposal_count=$10
             AND citation_set_sha256=CAST($11 AS char(64))
             AND proposal_set_sha256=CAST($12 AS char(64))
             AND validation_sha256=CAST($13 AS char(64))"#,
        turn.run_id,
        turn.turn_id,
        &turn.input_snapshot_sha256,
        output_sha256,
        &turn.output_schema_id,
        &turn.output_schema_version,
        &turn.output_schema_sha256,
        output_status,
        citations as i32,
        proposal_count,
        citation_set_sha256,
        proposal_set_sha256,
        validation_sha256,
        sha256(b"agent-output-validator-v2"),
        sha256(b"agent-output-policy-v2"),
        validated,
    )
    .fetch_optional(&mut *executor)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Terminal(
            "AGENT_OUTPUT_VALIDATION_REPLAY_MISMATCH",
            turn.run_id.to_string(),
        )
    })?;
    Ok(PersistedValidation { id, replayed: true })
}

async fn load_exact_proposal(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    validation_id: Uuid,
    proposal_type: &str,
    payload: &Value,
    payload_sha256: &str,
) -> Result<Uuid, Failure> {
    let payload_canonical = canonical_bytes(payload)?;
    let proposal_ids = sqlx::query_scalar!(
        r#"SELECT id FROM ops.agent_suggestions
           WHERE agent_run_id=$1 AND citation_validation_id=$2
             AND suggestion_type=$3 AND proposal_contract_version=2
             AND payload=$4 AND payload_sha256=CAST($5 AS char(64))
             AND input_snapshot_sha256=CAST($6 AS char(64))
             AND target_schema_version=$7
             AND evidence_ids='[]'::jsonb AND citation_checks='[]'::jsonb
             AND payload_canonical=$8
             AND convert_from(payload_canonical,'UTF8')::jsonb=payload"#,
        turn.run_id,
        validation_id,
        proposal_type,
        payload,
        payload_sha256,
        &turn.input_snapshot_sha256,
        &turn.output_schema_id,
        payload_canonical,
    )
    .fetch_all(&mut *executor)
    .await
    .map_err(database)?;
    match proposal_ids.as_slice() {
        [proposal_id] => Ok(*proposal_id),
        _ => Err(Failure::Terminal(
            "AGENT_PROPOSAL_REPLAY_MISMATCH",
            format!("{proposal_type}:{}", proposal_ids.len()),
        )),
    }
}

fn output_proposals(output: &Value) -> Result<Vec<(&'static str, Value)>, Failure> {
    let fields = [
        ("comparables", "COMPARABLE"),
        ("hypotheses", "HYPOTHESIS"),
        ("tasks", "TASK"),
        ("claims", "CLAIM"),
        ("communications", "COMMUNICATION"),
    ];
    let mut proposals = Vec::new();
    for (field, proposal_type) in fields {
        let Some(value) = output.get(field) else {
            continue;
        };
        let Some(items) = value.as_array() else {
            return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", field.to_owned()));
        };
        for item in items {
            if !item.is_object() {
                return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", field.to_owned()));
            }
            if proposal_type == "COMMUNICATION" {
                validate_communication_payload(item)?;
            }
            proposals.push((proposal_type, item.clone()));
        }
    }
    Ok(proposals)
}

fn communication_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn validate_communication_payload(payload: &Value) -> Result<(), Failure> {
    let object = payload.as_object().ok_or_else(|| {
        Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "communication payload object".to_owned(),
        )
    })?;
    validate_communication_fields(object)?;
    validate_communication_envelope(payload)?;
    require_communication_enum(
        payload,
        "channel",
        &[
            "SMTP_EMAIL",
            "TELEGRAM_BOT_API",
            "META_WHATSAPP_BUSINESS_CLOUD",
            "LINE_MESSAGING_API",
            "SOLAPI_SMS",
            "SOLAPI_KAKAO_BIZMESSAGE",
            "TWILIO_VOICE",
            "SIGNED_WEBHOOK",
        ],
    )?;
    require_communication_enum(
        payload,
        "purpose",
        &[
            "ENDPOINT_VERIFICATION",
            "RIGHT_OF_REPLY_REQUEST",
            "RIGHT_OF_REPLY_REMINDER",
            "RESPONSE_RECEIPT",
            "CORRECTION_STATUS",
            "CORRECTION_RETRACTION_NOTICE",
            "PRIVACY_TRANSACTIONAL_NOTICE",
            "SECURITY_TRANSACTIONAL_NOTICE",
            "SUBSCRIPTION_UPDATE",
            "PRODUCT_MARKETING",
            "INCIDENT_RECOVERY",
            "INTERNAL_ACTION_REQUEST",
            "DISCRETIONARY_OUTREACH",
        ],
    )?;
    validate_communication_text(payload)?;
    validate_communication_citations(payload)?;
    validate_recipient_binding(payload)
}

fn validate_communication_fields(object: &serde_json::Map<String, Value>) -> Result<(), Failure> {
    let allowed = [
        "schemaVersion",
        "kind",
        "recipientBinding",
        "channel",
        "purpose",
        "draftText",
        "rationale",
        "citationIds",
        "requiresApproval",
    ];
    if object.len() != allowed.len() || object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "communication payload closed fields".to_owned(),
        ));
    }
    Ok(())
}

fn validate_communication_envelope(payload: &Value) -> Result<(), Failure> {
    if payload.get("schemaVersion").and_then(Value::as_str)
        != Some("communication-proposal-payload.v1")
        || payload.get("kind").and_then(Value::as_str) != Some("COMMUNICATION")
        || payload.get("requiresApproval").and_then(Value::as_bool) != Some(true)
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "communication payload envelope".to_owned(),
        ));
    }
    Ok(())
}

fn require_communication_enum(
    payload: &Value,
    field: &'static str,
    allowed: &[&str],
) -> Result<(), Failure> {
    let value = payload
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !allowed.contains(&value) {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            format!("communication {field}"),
        ));
    }
    Ok(())
}

fn validate_communication_text(payload: &Value) -> Result<(), Failure> {
    for (key, maximum) in [("draftText", 10_000), ("rationale", 4_000)] {
        let length = payload
            .get(key)
            .and_then(Value::as_str)
            .map(str::chars)
            .map(Iterator::count)
            .unwrap_or_default();
        if !(1..=maximum).contains(&length) {
            return Err(Failure::Terminal(
                "AGENT_OUTPUT_INVALID",
                format!("communication {key}"),
            ));
        }
    }
    Ok(())
}

fn validate_communication_citations(payload: &Value) -> Result<(), Failure> {
    let citation_ids = payload
        .get("citationIds")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            Failure::Terminal(
                "AGENT_OUTPUT_INVALID",
                "communication citationIds".to_owned(),
            )
        })?;
    let unique = citation_ids
        .iter()
        .filter_map(Value::as_str)
        .filter_map(|value| Uuid::parse_str(value).ok())
        .collect::<BTreeSet<_>>();
    if !(1..=100).contains(&citation_ids.len()) || unique.len() != citation_ids.len() {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "communication citationIds".to_owned(),
        ));
    }
    Ok(())
}

fn validate_recipient_binding(payload: &Value) -> Result<(), Failure> {
    let binding = payload
        .get("recipientBinding")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            Failure::Terminal(
                "AGENT_OUTPUT_INVALID",
                "communication recipientBinding".to_owned(),
            )
        })?;
    let binding_fields = [
        "subjectId",
        "endpointId",
        "endpointVersion",
        "endpointDigest",
    ];
    if binding.len() != binding_fields.len()
        || binding
            .keys()
            .any(|key| !binding_fields.contains(&key.as_str()))
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "communication recipientBinding closed fields".to_owned(),
        ));
    }
    for key in ["subjectId", "endpointId"] {
        if binding
            .get(key)
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .is_none()
        {
            return Err(Failure::Terminal(
                "AGENT_OUTPUT_INVALID",
                format!("communication recipientBinding.{key}"),
            ));
        }
    }
    if binding
        .get("endpointVersion")
        .and_then(Value::as_i64)
        .is_none_or(|value| value < 1)
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "communication endpointVersion".to_owned(),
        ));
    }
    if binding
        .get("endpointDigest")
        .and_then(Value::as_str)
        .is_none_or(|value| !communication_sha256(value))
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "communication recipientBinding.endpointDigest".to_owned(),
        ));
    }
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "proposal citation insertion binds provider turn, validation, payload, output, and hypothesis provenance"
)]
async fn insert_proposal_citations(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    validation_id: Uuid,
    proposal_id: Uuid,
    proposal_type: &str,
    payload: &Value,
    output: &Value,
    payload_sha256: &str,
    hypothesis: Option<&HypothesisMaterialization>,
) -> Result<(), Failure> {
    let citations = resolve_citations(payload, output)?;
    let expected_ids = hypothesis.map(|value| value.citation_ids.as_slice());
    if expected_ids.is_some_and(|ids| ids.len() != citations.len()) {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "hypothesis citation identifier count".to_owned(),
        ));
    }
    for (ordinal, citation, source_use_sha256) in citations {
        persist_citation(
            executor,
            turn,
            validation_id,
            proposal_id,
            proposal_type,
            ordinal,
            citation.get("supports").and_then(Value::as_str),
            payload_sha256,
            &source_use_sha256,
            expected_ids.and_then(|ids| ids.get(ordinal)).copied(),
        )
        .await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_communication() -> Value {
        json!({
            "schemaVersion": "communication-proposal-payload.v1",
            "kind": "COMMUNICATION",
            "recipientBinding": {
                "subjectId": "00000000-0000-0000-0000-000000000001",
                "endpointId": "00000000-0000-0000-0000-000000000002",
                "endpointVersion": 1,
                "endpointDigest": "1".repeat(64)
            },
            "channel": "SMTP_EMAIL",
            "purpose": "RIGHT_OF_REPLY_REQUEST",
            "draftText": "답변 요청 본문",
            "rationale": "검증된 근거에 대한 답변권 보장",
            "citationIds": ["00000000-0000-0000-0000-000000000003"],
            "requiresApproval": true
        })
    }

    #[test]
    fn communication_payload_accepts_only_the_closed_schema() {
        assert!(validate_communication_payload(&valid_communication()).is_ok());
        let mut extra = valid_communication();
        extra["provider"] = json!("smtp");
        assert!(validate_communication_payload(&extra).is_err());
    }

    #[test]
    fn communication_payload_rejects_aliases_and_invalid_bindings() {
        let mut alias = valid_communication();
        alias["channel"] = json!("EMAIL");
        assert!(validate_communication_payload(&alias).is_err());

        let mut invalid_binding = valid_communication();
        invalid_binding["recipientBinding"]["endpointDigest"] = json!("not-a-digest");
        assert!(validate_communication_payload(&invalid_binding).is_err());

        let mut duplicate = valid_communication();
        duplicate["citationIds"] = json!([
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000003"
        ]);
        assert!(validate_communication_payload(&duplicate).is_err());
    }
}
