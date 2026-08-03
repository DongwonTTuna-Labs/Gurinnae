async fn complete_provider_turn(
    state: &State,
    turn: &ProviderTurnIdentity,
    receipt: &Value,
    receipt_id: Uuid,
    output: &Value,
    actual_cost: i64,
) -> Result<(), Failure> {
    let receipt_canonical = canonical_bytes(receipt)?;
    let receipt_sha256 = sha256(&receipt_canonical);
    let envelope_payload_sha256 = sha256(&canonical_bytes(output)?);
    let envelope = json!({
        "kind":"FINAL_OUTPUT",
        "payloadSha256":envelope_payload_sha256
    });
    let envelope_canonical = canonical_bytes(&envelope)?;
    let envelope_sha256 = sha256(&envelope_canonical);
    let provider_request_hash = receipt
        .get("providerRequestIdHash")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            Failure::Terminal("PROVIDER_RECEIPT_INVALID", "providerRequestIdHash".into())
        })?;
    let redaction_receipt_sha256 = sha256(&canonical_bytes(&json!({
        "envelopeSha256": envelope_sha256,
        "providerRequestIdHash": provider_request_hash,
        "outputSha256": envelope_payload_sha256
    }))?);
    let response = json!({
        "schemaVersion":"agent-provider-response-redacted.v2",
        "finishReason":"FINAL_OUTPUT",
        "envelopeSha256":envelope_sha256,
        "safetyCodes":[],
        "providerRequestIdHash":provider_request_hash,
        "redactionReceiptSha256":redaction_receipt_sha256
    });
    let response_canonical = canonical_bytes(&response)?;
    validate_typed_provider_output(state, turn, output, actual_cost).await?;
    let (provider_turn, turn_transcript_sha256) = terminal_provider_turn(
        turn,
        "COMPLETED",
        Some(&envelope),
        Some(&response),
        receipt,
        receipt_sha256.as_str(),
        None,
        None,
        Some(envelope_payload_sha256.as_str()),
    )?;
    let provider_turn_canonical = canonical_bytes(&provider_turn)?;
    persist_completed_provider_turn(
        state,
        turn,
        receipt_id,
        receipt,
        &receipt_canonical,
        &receipt_sha256,
        &envelope_canonical,
        &envelope_sha256,
        &envelope_payload_sha256,
        &response,
        &response_canonical,
        provider_request_hash,
        &provider_turn_canonical,
        &turn_transcript_sha256,
        output,
        actual_cost,
    )
    .await?;
    Ok(())
}

#[expect(clippy::too_many_arguments, reason = "tool-call completion binds receipt and response lineage fields")]
async fn complete_provider_turn_tool_call(
    state: &State,
    turn: &ProviderTurnIdentity,
    receipt: &Value,
    receipt_id: Uuid,
    call: &ToolCall,
    result: &Value,
    transcript_sha256: &str,
    actual_cost: i64,
) -> Result<(), Failure> {
    let receipt_canonical = canonical_bytes(receipt)?;
    let receipt_sha256 = sha256(&receipt_canonical);
    let envelope = json!({
        "kind":"TOOL_CALL",
        "callId":call.call_id,
        "toolId":call.request.tool_id().wire_name(),
        "argumentsSha256":call.request_sha256
    });
    let envelope_canonical = canonical_bytes(&envelope)?;
    let envelope_sha256 = sha256(&envelope_canonical);
    let payload_sha256 = sha256(&canonical_bytes(result)?);
    let provider_request_hash = receipt
        .get("providerRequestIdHash")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_RECEIPT_INVALID", "providerRequestIdHash".into()))?;
    let response = json!({
        "schemaVersion":"agent-provider-response-redacted.v2",
        "finishReason":"TOOL_CALL",
        "envelopeSha256":envelope_sha256,
        "safetyCodes":[],
        "providerRequestIdHash":provider_request_hash,
        "redactionReceiptSha256":sha256(&canonical_bytes(&json!({"envelopeSha256":envelope_sha256,"providerRequestIdHash":provider_request_hash,"outputSha256":payload_sha256}))?)
    });
    let response_canonical = canonical_bytes(&response)?;
    let (provider_turn, turn_digest) = terminal_provider_turn(
        turn,
        "COMPLETED",
        Some(&envelope),
        Some(&response),
        receipt,
        receipt_sha256.as_str(),
        None,
        None,
        Some(call.request_sha256.as_str()),
    )?;
    let provider_turn_canonical = canonical_bytes(&provider_turn)?;
    let transcript = if transcript_sha256.is_empty() { turn_digest } else { transcript_sha256.to_owned() };
    let input_units = receipt.pointer("/usage/inputUnits").and_then(Value::as_i64);
    let output_units = receipt.pointer("/usage/outputUnits").and_then(Value::as_i64);
    let mut tx = state.pool.begin().await.map_err(database)?;
    complete_provider_turn_owner(
        &mut *tx,
        turn,
        1,
        "COMPLETED",
        Some("TOOL_CALL"),
        Some(envelope_sha256.as_str()),
        Some(call.request_sha256.as_str()),
        Some(&envelope_canonical),
        Some(&response),
        Some(&response_canonical),
        Some(call.call_id.to_string().as_str()),
        Some(call.request.tool_id().wire_name()),
        receipt_id,
        receipt,
        &receipt_canonical,
        &receipt_sha256,
        &provider_turn_canonical,
        &sha256(&provider_turn_canonical),
        Some(&transcript),
        input_units,
        output_units,
        Some(provider_request_hash),
        Some(actual_cost),
        None,
        None,
    )
    .await?;
    insert_model_input_source_uses(&mut tx, turn, Some(receipt_id), Some(&receipt_sha256)).await?;
    tx.commit().await.map_err(database)
}

#[expect(clippy::too_many_arguments, reason = "completion projection binds immutable receipt and envelope hashes")]
async fn persist_completed_provider_turn(
    state: &State,
    turn: &ProviderTurnIdentity,
    receipt_id: Uuid,
    receipt: &Value,
    receipt_canonical: &[u8],
    receipt_sha256: &str,
    envelope_canonical: &[u8],
    envelope_sha256: &str,
    envelope_payload_sha256: &str,
    response: &Value,
    response_canonical: &[u8],
    provider_request_hash: &str,
    provider_turn_canonical: &[u8],
    turn_transcript_sha256: &str,
    output: &Value,
    actual_cost: i64,
) -> Result<(), Failure> {
    let mut tx = state.pool.begin().await.map_err(database)?;
    let input_units = receipt.get("usage").and_then(|u| u.get("inputUnits")).and_then(Value::as_i64);
    let output_units = receipt.get("usage").and_then(|u| u.get("outputUnits")).and_then(Value::as_i64);
    complete_provider_turn_owner(
        &mut *tx, turn, 1, "COMPLETED", Some("FINAL_OUTPUT"),
        Some(envelope_sha256), Some(envelope_payload_sha256), Some(envelope_canonical),
        Some(response), Some(response_canonical), None, None, receipt_id, receipt,
        receipt_canonical, receipt_sha256, provider_turn_canonical,
        &sha256(provider_turn_canonical), Some(turn_transcript_sha256),
        input_units, output_units, Some(provider_request_hash), Some(actual_cost), None, None,
    ).await?;
    insert_model_input_source_uses(&mut tx, turn, Some(receipt_id), Some(receipt_sha256)).await?;
    insert_model_output_derivation_source_uses(
        &mut tx,
        turn,
        receipt_id,
        receipt_sha256,
        output,
    )
    .await?;
    insert_citation_source_uses(&mut tx, turn, output).await?;
    insert_output_validation(
        &mut tx,
        turn,
        output,
        envelope_payload_sha256,
        receipt_sha256,
    )
    .await?;
    tx.commit().await.map_err(database)
}

/// Preserve a durable validation receipt even when a provider response is
/// rejected before normal completion.  Invalid output is an auditable failed
/// attempt, not an unrecorded transport retry.
async fn insert_output_validation_failure(
    state: &State,
    turn: &ProviderTurnIdentity,
    output: &Value,
    failure_code: &str,
    detail: &str,
) -> Result<(), Failure> {
    let output_sha256 = sha256(&canonical_bytes(output)?);
    let empty_set_sha256 = sha256(b"[]");
    let validation_sha256 = sha256(&canonical_bytes(&json!({
        "agentRunId": turn.run_id,
        "providerTurnId": turn.turn_id,
        "providerOutputSha256": output_sha256,
        "failureCode": failure_code,
        "detail": detail,
    }))?);
    sqlx::query!(
        "INSERT INTO ops.agent_output_validations(
          agent_run_id,provider_turn_id,input_snapshot_sha256,provider_output_sha256,
          validator_version,validator_sha256,output_schema_id,output_schema_version,
          output_schema_sha256,validation_policy_version,validation_policy_sha256,
          validation_status,schema_status,citation_status,policy_status,run_terminal_status,
          output_status,failure_code,failure_details_redacted,validated_outcome,
          validated_outcome_sha256,citation_count,proposal_count,citation_set_sha256,
          proposal_set_sha256,validation_sha256)
         VALUES($1,$2,$3,CAST($4 AS char(64)),'agent-output-validator-v2',CAST($5 AS char(64)),
          $6,$7,CAST($8 AS char(64)),'agent-output-policy-v2',CAST($9 AS char(64)),
          'INVALID','FAIL','NOT_RUN','NOT_RUN','FAILED',
          $10,$11,$12::jsonb,NULL,NULL,0,0,CAST($13 AS char(64)),CAST($13 AS char(64)),CAST($14 AS char(64)))
         ON CONFLICT(agent_run_id,provider_turn_id) DO NOTHING",
        turn.run_id,
        turn.turn_id,
        &turn.input_snapshot_sha256,
        &output_sha256,
        sha256(b"agent-output-validator-v2"),
        &turn.output_schema_id,
        &turn.output_schema_version,
        &turn.output_schema_sha256,
        sha256(b"agent-output-policy-v2"),
        match output.get("outcome").and_then(Value::as_str) {
            Some("ABSTAINED") => "ABSTAINED",
            _ => "COMPLETED",
        },
        failure_code,
        json!({"reason": detail.chars().take(512).collect::<String>()}),
        &empty_set_sha256,
        &validation_sha256,
    )
    .execute(&state.pool)
    .await
    .map_err(database)?;
    Ok(())
}

include!("analysis_provider_lineage.rs");

async fn complete_provider_turn_failure(
    state: &State,
    turn: &ProviderTurnIdentity,
    receipt: &Value,
    receipt_id: Uuid,
    error_code: &str,
) -> Result<(), Failure> {
    let receipt_canonical = canonical_bytes(receipt)?;
    let receipt_sha256 = sha256(&receipt_canonical);
    let provider_request_hash = receipt
        .get("providerRequestIdHash")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let status = match error_code {
        "PROVIDER_RATE_LIMITED" => "RATE_LIMITED",
        "PROVIDER_TIMEOUT" => "TIMED_OUT",
        "PROVIDER_CANCELLED" => "CANCELLED",
        "PROVIDER_OUTCOME_UNKNOWN" => "OUTCOME_UNKNOWN",
        _ => "PROVIDER_FAILED",
    };
    let (turn_payload, _) = terminal_provider_turn(
        turn,
        status,
        None,
        None,
        receipt,
        receipt_sha256.as_str(),
        Some(error_code),
        Some(sha256(error_code.as_bytes()).as_str()),
        None,
    )?;
    let turn_canonical = canonical_bytes(&turn_payload)?;
    complete_provider_turn_owner(
        &state.pool,
        turn,
        1,
        status,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        receipt_id,
        receipt,
        &receipt_canonical,
        &receipt_sha256,
        &turn_canonical,
        &sha256(&turn_canonical),
        None,
        receipt
            .get("usage")
            .and_then(|u| u.get("inputUnits"))
            .and_then(Value::as_i64),
        receipt
            .get("usage")
            .and_then(|u| u.get("outputUnits"))
            .and_then(Value::as_i64),
        provider_request_hash.as_deref(),
        None,
        Some(error_code),
        Some(&sha256(error_code.as_bytes())),
    )
    .await
}

#[expect(clippy::too_many_arguments, reason = "provider turn projection is the immutable V2 contract")]
fn terminal_provider_turn(
    turn: &ProviderTurnIdentity,
    status: &str,
    envelope: Option<&Value>,
    response_redacted: Option<&Value>,
    receipt: &Value,
    receipt_sha256: &str,
    error_code: Option<&str>,
    error_sha256: Option<&str>,
    output_sha256: Option<&str>,
) -> Result<(Value, String), Failure> {
    let completed_at = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|error| Failure::Terminal("PROVIDER_RECEIPT_INVALID", error.to_string()))?;
    let mut value = json!({
        "schemaVersion":"provider-turn.v2",
        "providerTurnId":turn.turn_id,
        "agentRunId":receipt.get("agentRunId").cloned().unwrap_or(Value::Null),
        "inputSnapshotSha256":turn.input_snapshot_sha256,
        "turnSequence":turn.turn_sequence,
        "attemptSequence":turn.attempt_sequence,
        "priorTranscriptSha256":turn.prior_transcript_sha256,
        "providerMode":turn.provider_mode,
        "providerConfigId":turn.provider_config_id,
        "providerCandidateId":turn.provider_candidate_id,
        "modelId":turn.model_id,
        "modelConfigurationSha256":turn.model_configuration_sha256,
        "routingPolicyVersion":turn.routing_policy_version,
        "routingDecisionSha256":turn.routing_decision_sha256,
        "promptId":turn.prompt_id,
        "promptVersion":turn.prompt_version,
        "promptSha256":turn.prompt_sha256,
        "outputSchemaId":turn.output_schema_id,
        "outputSchemaVersion":turn.output_schema_version,
        "outputSchemaSha256":turn.output_schema_sha256,
        "classification":turn.classification,
        "modelUseRightsSha256":turn.model_use_rights_sha256,
        "budgetReservationKeySha256":turn.budget_reservation_key_sha256,
        "dispatchKeySha256":turn.dispatch_key_sha256,
        "requestSha256":turn.request_sha256,
        "requestRedacted":turn.request_redacted,
        "status":status,
        "envelope":envelope.cloned().unwrap_or(Value::Null),
        "responseRedacted":response_redacted.cloned().unwrap_or(Value::Null),
        "providerReceipt":receipt,
        "turnTranscriptSha256":Value::Null,
        "inputUnits":receipt.pointer("/usage/inputUnits").cloned().unwrap_or(Value::Null),
        "outputUnits":receipt.pointer("/usage/outputUnits").cloned().unwrap_or(Value::Null),
        "latencyMs":Value::Null,
        "costEventId":Value::Null,
        "errorCode":error_code,
        "errorSha256":error_sha256,
        "version":2,
        "dispatchedAt":turn.dispatched_at,
        "completedAt":completed_at
    });
    let transcript = json!({
        "schemaVersion": "agent-transcript.final-turn.v1",
        "priorTranscriptSha256": turn.prior_transcript_sha256,
        "providerTurnDigest": sha256(&canonical_bytes(&value)?),
        "providerReceiptDigest": receipt_sha256,
        "outputPayloadSha256": output_sha256
    });
    let transcript_sha256 = sha256(&canonical_bytes(&transcript)?);
    value["turnTranscriptSha256"] = json!(if status == "COMPLETED" {
        transcript_sha256.clone()
    } else {
        String::new()
    });
    if status != "COMPLETED" {
        value["turnTranscriptSha256"] = Value::Null;
    }
    Ok((value, transcript_sha256))
}
