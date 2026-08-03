use super::*;
use std::collections::BTreeSet;

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
    let validation_id = persist_validation(
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
    for (proposal_type, payload) in proposals {
        let payload_canonical = canonical_bytes(&payload)?;
        let payload_sha256 = sha256(&payload_canonical);
        let proposal_id: Uuid = sqlx::query_scalar(
            r#"INSERT INTO ops.agent_suggestions(
               agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status,
               proposal_contract_version,target_schema_version,payload_sha256,payload_canonical,
               input_snapshot_sha256,citation_validation_id,expires_at)
             SELECT $1,(SELECT case_id FROM ops.agent_runs WHERE id=$1),$2,$3,'[]'::jsonb,'[]'::jsonb,'PENDING',2,$4,CAST($5 AS char(64)),$6,
                    $7,$8,clock_timestamp()+interval '7 days'
             WHERE NOT EXISTS (SELECT 1 FROM ops.agent_suggestions WHERE agent_run_id=$1 AND citation_validation_id=$9 AND payload_sha256=CAST($5 AS char(64)))
             RETURNING id"#,
        )
        .bind(turn.run_id).bind(proposal_type).bind(&payload).bind(&turn.output_schema_id)
        .bind(&payload_sha256).bind(payload_canonical).bind(&turn.input_snapshot_sha256)
        .bind(validation_id).fetch_one(&mut *executor).await.map_err(database)?;
        insert_proposal_citations(
            executor,
            turn,
            validation_id,
            proposal_id,
            &payload,
            output,
            &payload_sha256,
        )
        .await?;
    }
    Ok(())
}

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
) -> Result<Uuid, Failure> {
    let output_status = output.get("status").or_else(|| output.get("outcome"))
        .and_then(Value::as_str).unwrap_or("COMPLETED");
    let inserted: Option<Uuid> = sqlx::query_scalar(
        r#"INSERT INTO ops.agent_output_validations(
          agent_run_id,provider_turn_id,input_snapshot_sha256,provider_output_sha256,validator_version,validator_sha256,
          output_schema_id,output_schema_version,output_schema_sha256,validation_policy_version,validation_policy_sha256,
          validation_status,schema_status,citation_status,policy_status,run_terminal_status,output_status,failure_details_redacted,
          validated_outcome,validated_outcome_sha256,citation_count,proposal_count,citation_set_sha256,proposal_set_sha256,validation_sha256)
         VALUES($1,$2,$3,CAST($4 AS char(64)),'agent-output-validator-v2',CAST($5 AS char(64)),
          $6,$7,CAST($8 AS char(64)),'agent-output-policy-v2',CAST($9 AS char(64)),
          'VALID','PASS','PASS','PASS','SUCCEEDED',$10,'{}'::jsonb,$11,CAST($12 AS char(64)),$13,$14,CAST($15 AS char(64)),CAST($16 AS char(64)),CAST($17 AS char(64)))
         ON CONFLICT(agent_run_id,provider_turn_id) DO NOTHING RETURNING validation_id"#,
    )
    .bind(turn.run_id).bind(turn.turn_id).bind(&turn.input_snapshot_sha256)
    .bind(output_sha256).bind(sha256(b"agent-output-validator-v2"))
    .bind(&turn.output_schema_id).bind(&turn.output_schema_version).bind(&turn.output_schema_sha256)
    .bind(sha256(b"agent-output-policy-v2")).bind(output_status).bind(validated)
    .bind(output_sha256).bind(citations as i32).bind(proposal_count)
    .bind(citation_set_sha256).bind(proposal_set_sha256).bind(validation_sha256)
    .fetch_optional(&mut *executor).await.map_err(database)?;
    if let Some(id) = inserted { return Ok(id); }
    sqlx::query_scalar("SELECT validation_id FROM ops.agent_output_validations WHERE agent_run_id=$1 AND provider_turn_id=$2")
        .bind(turn.run_id).bind(turn.turn_id).fetch_one(&mut *executor).await.map_err(database)
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
    if payload.get("schemaVersion").and_then(Value::as_str) != Some("communication-proposal-payload.v1")
        || payload.get("kind").and_then(Value::as_str) != Some("COMMUNICATION")
        || payload.get("requiresApproval").and_then(Value::as_bool) != Some(true)
    {
        return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "communication payload envelope".to_owned()));
    }
    Ok(())
}

fn require_communication_enum(
    payload: &Value,
    field: &'static str,
    allowed: &[&str],
) -> Result<(), Failure> {
    let value = payload.get(field).and_then(Value::as_str).unwrap_or_default();
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
    let binding = payload.get("recipientBinding").and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", "communication recipientBinding".to_owned()))?;
    let binding_fields = ["subjectId", "endpointId", "endpointVersion", "endpointDigest"];
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
    if binding.get("endpointVersion").and_then(Value::as_i64).is_none_or(|value| value < 1) {
        return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "communication endpointVersion".to_owned()));
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

async fn insert_proposal_citations(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    validation_id: Uuid,
    proposal_id: Uuid,
    payload: &Value,
    output: &Value,
    payload_sha256: &str,
) -> Result<(), Failure> {
    let citations = resolve_citations(payload, output)?;
    for (ordinal, citation, source_use_sha256) in citations {
        persist_citation(
            executor,
            turn,
            validation_id,
            proposal_id,
            ordinal,
            citation.get("supports").and_then(Value::as_str),
            payload_sha256,
            &source_use_sha256,
        )
        .await?;
    }
    Ok(())
}

fn resolve_citations(payload: &Value, output: &Value) -> Result<Vec<(usize, Value, String)>, Failure> {
    let output_citations = output.get("citations").and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", "citations".to_owned()))?;
    let mut refs = Vec::new();
    for key in ["citationIndexes", "supportingCitationIndexes", "contradictingCitationIndexes", "citationRefs", "citations"] {
        if let Some(value) = payload.get(key) {
            let items = value.as_array().ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", format!("{key} must be an array")))?;
            refs.extend(items.iter().cloned());
        }
    }
    if let Some(items) = payload.get("citationIds").or_else(|| payload.get("payload").and_then(|value| value.get("citationIds"))) {
        let items = items.as_array().ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", "citationIds must be an array".to_owned()))?;
        for id in items {
            let id = id.as_str().ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", "citationId".to_owned()))?;
            refs.push(output_citations_placeholder(output, id).ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", format!("unknown citationId: {id}")))?);
        }
    }
    if refs.is_empty() { return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "proposal citation missing".to_owned())); }
    let mut seen = std::collections::BTreeSet::new();
    refs.into_iter().enumerate().map(|(ordinal, reference)| {
        let citation = if let Some(index) = reference.as_u64() {
            output_citations.get(usize::try_from(index).map_err(|_| Failure::Terminal("AGENT_OUTPUT_INVALID", "citation index".to_owned()))?).cloned()
                .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", format!("citation index out of range: {index}")))?
        } else if let Some(value) = reference.as_str() { json!({"sourceUseSha256": value}) } else { reference };
        if !citation.is_object() { return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "citation object".to_owned())); }
        let source = citation.get("sourceUseSha256").and_then(Value::as_str).or_else(|| citation.get("source_use_sha256").and_then(Value::as_str))
            .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
            .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", "citation sourceUseSha256".to_owned()))?;
        if citation.get("supports").and_then(Value::as_str).is_none()
            || (citation.get("supportsSha256").and_then(Value::as_str).is_none()
                && citation.get("supports_sha256").and_then(Value::as_str).is_none())
        { return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "citation supports".to_owned())); }
        if !seen.insert(source.to_ascii_lowercase()) { return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "duplicate citation".to_owned())); }
        let source = source.to_owned();
        Ok((ordinal, citation, source))
    }).collect()
}

async fn persist_citation(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    validation_id: Uuid,
    proposal_id: Uuid,
    ordinal: usize,
    supports: Option<&str>,
    payload_sha256: &str,
    source_use_sha256: &str,
) -> Result<(), Failure> {
    let ordinal = i32::try_from(ordinal)
        .map_err(|_| Failure::Terminal("AGENT_OUTPUT_INVALID", "citation ordinal".to_owned()))?;
    let result = sqlx::query(
        "INSERT INTO ops.agent_proposal_citations(\
          proposal_id,agent_run_id,provider_turn_id,validation_id,dataset_snapshot_id,snapshot_member_id,snapshot_member_digest,\
          citation_ordinal,input_snapshot_sha256,proposal_payload_sha256,source_kind,source_use_id,source_use_sha256,\
          evidence_segment_id,source_id,locator_kind,locator_value,locator_digest,content_sha256,supports_redacted,supports_sha256,citation_digest)\
         SELECT $1,s.agent_run_id,s.provider_turn_id,$2,s.dataset_snapshot_id,s.snapshot_member_id,s.snapshot_member_digest,$3,\
                $4,CAST($5 AS char(64)),s.source_kind,s.source_use_id,s.source_use_sha256,s.evidence_segment_id,\
                COALESCE(s.source_document_id,s.research_artifact_id),s.locator_kind,s.locator_value,\
                s.locator_sha256,s.selected_content_sha256,$6,encode(extensions.digest(convert_to($6,'UTF8'),'sha256'),'hex'),\
                encode(extensions.digest(convert_to($1::text||':'||$3::text||':'||s.source_use_sha256,'UTF8'),'sha256'),'hex')\
           FROM ops.agent_source_uses s WHERE s.agent_run_id=$7 AND s.use_kind='CITATION'\
            AND s.parent_source_use_sha256=CAST($8 AS char(64))\
            AND s.locator_kind IS NOT NULL AND s.locator_value IS NOT NULL AND s.locator_sha256 IS NOT NULL\
            AND s.selected_content_sha256 IS NOT NULL LIMIT 1\
         ON CONFLICT (proposal_id,citation_ordinal) DO NOTHING",
    )
    .bind(proposal_id).bind(validation_id).bind(ordinal).bind(&turn.input_snapshot_sha256)
    .bind(payload_sha256).bind(supports).bind(turn.run_id).bind(source_use_sha256)
    .execute(&mut *executor).await.map_err(database)?;
    if result.rows_affected() != 1 {
        return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "citation source use not found".to_owned()));
    }
    Ok(())
}

fn output_citations_placeholder(output: &Value, citation_id: &str) -> Option<Value> {
    output
        .get("citations")?
        .as_array()?
        .iter()
        .find(|citation| citation.get("citationId").and_then(Value::as_str) == Some(citation_id))
        .cloned()
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
