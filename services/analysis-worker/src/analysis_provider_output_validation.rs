use super::*;

pub(super) async fn insert_output_validation(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    output: &Value,
    output_sha256: &str,
    receipt_sha256: &str,
) -> Result<(), Failure> {
    let citations = output.get("citations").and_then(Value::as_array).map_or(0, Vec::len);
    let citation_set_sha256 = sha256(&canonical_bytes(&output.get("citations").cloned().unwrap_or_else(|| json!([])))?);
    let proposals = output_proposals(output)?;
    if !proposals.is_empty() && citations == 0 {
        return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "each proposal requires at least one citation".to_owned()));
    }
    let proposal_count = i32::try_from(proposals.len())
        .map_err(|_| Failure::Terminal("AGENT_OUTPUT_INVALID", "proposal count".to_owned()))?;
    let proposal_payloads = Value::Array(proposals.iter().map(|(_, payload)| payload.clone()).collect());
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
    let inserted_validation_id: Option<Uuid> = sqlx::query_scalar(
        r#"INSERT INTO ops.agent_output_validations(
          agent_run_id,provider_turn_id,input_snapshot_sha256,provider_output_sha256,validator_version,validator_sha256,
          output_schema_id,output_schema_version,output_schema_sha256,validation_policy_version,validation_policy_sha256,
          validation_status,schema_status,citation_status,policy_status,run_terminal_status,output_status,failure_details_redacted,
          validated_outcome,validated_outcome_sha256,citation_count,proposal_count,citation_set_sha256,proposal_set_sha256,validation_sha256)
         VALUES($1,$2,$3,CAST($4 AS char(64)),'agent-output-validator-v2',CAST($5 AS char(64)),
          $6,$7,CAST($8 AS char(64)),'agent-output-policy-v2',CAST($9 AS char(64)),
          'VALID','PASS','PASS','PASS','SUCCEEDED',$10,'{}'::jsonb,$11,CAST($12 AS char(64)),$13,$14,CAST($15 AS char(64)),CAST($16 AS char(64)),CAST($17 AS char(64)))
         ON CONFLICT(agent_run_id,provider_turn_id) DO NOTHING
         RETURNING validation_id"#,
    )
    .bind(turn.run_id)
    .bind(turn.turn_id)
    .bind(&turn.input_snapshot_sha256)
    .bind(output_sha256)
    .bind(sha256(b"agent-output-validator-v2"))
    .bind(&turn.output_schema_id)
    .bind(&turn.output_schema_version)
    .bind(&turn.output_schema_sha256)
    .bind(sha256(b"agent-output-policy-v2"))
    .bind(output.get("status").or_else(|| output.get("outcome")).and_then(Value::as_str).unwrap_or("COMPLETED"))
    .bind(&validated)
    .bind(output_sha256)
    .bind(citations as i32)
    .bind(proposal_count)
    .bind(citation_set_sha256)
    .bind(&proposal_set_sha256)
    .bind(validation_sha256)
    .fetch_optional(&mut *executor)
    .await
    .map_err(database)?;
    let validation_id = if let Some(id) = inserted_validation_id { id } else {
        sqlx::query_scalar("SELECT validation_id FROM ops.agent_output_validations WHERE agent_run_id=$1 AND provider_turn_id=$2")
            .bind(turn.run_id).bind(turn.turn_id).fetch_one(&mut *executor).await.map_err(database)?
    };
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
        insert_proposal_citations(executor, turn, validation_id, proposal_id, &payload, output, &payload_sha256).await?;
    }
    Ok(())
}

fn output_proposals(output: &Value) -> Result<Vec<(&'static str, Value)>, Failure> {
    let fields = [("comparables", "COMPARABLE"), ("hypotheses", "HYPOTHESIS"), ("tasks", "TASK"), ("claims", "CLAIM"), ("communications", "COMMUNICATION")];
    let mut proposals = Vec::new();
    for (field, proposal_type) in fields {
        let Some(value) = output.get(field) else { continue };
        let Some(items) = value.as_array() else { return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", field.to_owned())) };
        for item in items {
            if !item.is_object() { return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", field.to_owned())) }
            proposals.push((proposal_type, item.clone()));
        }
    }
    Ok(proposals)
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
    let citations = payload.get("citationIndexes").or_else(|| payload.get("supportingCitationIndexes"))
        .or_else(|| payload.get("citationRefs")).or_else(|| payload.get("citations"));
    let Some(citations) = citations.and_then(Value::as_array) else { return Ok(()) };
    for (ordinal, citation_ref) in citations.iter().enumerate() {
        let citation = if let Some(index) = citation_ref.as_u64() {
            output.get("citations").and_then(Value::as_array)
                .and_then(|values| values.get(usize::try_from(index).ok()?)).cloned().unwrap_or(Value::Null)
        } else { citation_ref.clone() };
        let source_use_sha256 = citation.get("sourceUseSha256").and_then(Value::as_str)
            .or_else(|| citation.get("source_use_sha256").and_then(Value::as_str));
        let Some(source_use_sha256) = source_use_sha256 else { continue };
        sqlx::query(
            "INSERT INTO ops.agent_proposal_citations(\
              proposal_id,agent_run_id,provider_turn_id,validation_id,dataset_snapshot_id,snapshot_member_id,snapshot_member_digest,\
              citation_ordinal,input_snapshot_sha256,proposal_payload_sha256,source_kind,source_use_id,source_use_sha256,\
              evidence_segment_id,source_id,locator_kind,locator_value,locator_digest,content_sha256,supports_redacted,supports_sha256,citation_digest)\
             SELECT $1,s.agent_run_id,s.provider_turn_id,$2,s.dataset_snapshot_id,s.snapshot_member_id,s.snapshot_member_digest,$3,\
                    $4,CAST($5 AS char(64)),s.source_kind,s.source_use_id,s.source_use_sha256,s.evidence_segment_id,\
                    COALESCE(s.source_document_id,s.research_artifact_id),COALESCE(s.locator_kind,'TEXT_RANGE'),COALESCE(s.locator_value,'citation'),\
                    COALESCE(s.locator_sha256,encode(extensions.digest(convert_to('citation','UTF8'),'sha256'),'hex')),\
                    s.selected_content_sha256,COALESCE($6,'citation'),encode(extensions.digest(convert_to(COALESCE($6,'citation'),'UTF8'),'sha256'),'hex'),\
                    encode(extensions.digest(convert_to($1::text||':'||$3::text||':'||s.source_use_sha256,'UTF8'),'sha256'),'hex')\
               FROM ops.agent_source_uses s\
              WHERE s.agent_run_id=$7 AND s.use_kind='CITATION' AND s.parent_source_use_sha256=CAST($8 AS char(64))\
              LIMIT 1\
             ON CONFLICT (proposal_id,citation_ordinal) DO NOTHING",
        )
        .bind(proposal_id).bind(validation_id)
        .bind(i32::try_from(ordinal).map_err(|_| Failure::Terminal("AGENT_OUTPUT_INVALID", "citation ordinal".to_owned()))?)
        .bind(&turn.input_snapshot_sha256).bind(payload_sha256)
        .bind(citation.get("supports").and_then(Value::as_str)).bind(turn.run_id).bind(source_use_sha256)
        .execute(&mut *executor).await.map_err(database)?;
    }
    Ok(())
}
