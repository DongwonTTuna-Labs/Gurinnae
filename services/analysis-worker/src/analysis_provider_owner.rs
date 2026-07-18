#[allow(clippy::too_many_arguments)]
async fn complete_provider_turn_owner<'a, E>(
    executor: E,
    turn: &ProviderTurnIdentity,
    expected_version: i64,
    status: &str,
    envelope_kind: Option<&str>,
    envelope_sha256: Option<&str>,
    envelope_payload_sha256: Option<&str>,
    envelope_canonical: Option<&[u8]>,
    response_redacted: Option<&Value>,
    response_redacted_canonical: Option<&[u8]>,
    call_id: Option<&str>,
    tool_id: Option<&str>,
    receipt_id: Uuid,
    receipt: &Value,
    receipt_canonical: &[u8],
    receipt_sha256: &str,
    provider_turn_canonical: &[u8],
    provider_turn_sha256: &str,
    turn_transcript_sha256: Option<&str>,
    input_units: Option<i64>,
    output_units: Option<i64>,
    provider_request_id_hash: Option<&str>,
    cost_krw: Option<i64>,
    error_code: Option<&str>,
    error_sha256: Option<&str>,
) -> Result<(), Failure>
where
    E: sqlx::Executor<'a, Database = sqlx::Postgres>,
{
    sqlx::query(
        "SELECT ops.complete_agent_provider_turn(
           $1,$2,$3,$4,CAST($5 AS char(64)),CAST($6 AS char(64)),$7,$8,$9,$10,$11,$12,$13,$14,
           CAST($15 AS char(64)),$16,CAST($17 AS char(64)),CAST($18 AS char(64)),$19,$20,
           CAST($21 AS char(64)),$22,$23,CAST($24 AS char(64)))",
    )
    .bind(turn.turn_id)
    .bind(expected_version)
    .bind(status)
    .bind(envelope_kind)
    .bind(envelope_sha256)
    .bind(envelope_payload_sha256)
    .bind(envelope_canonical)
    .bind(response_redacted)
    .bind(response_redacted_canonical)
    .bind(call_id)
    .bind(tool_id)
    .bind(receipt_id)
    .bind(receipt)
    .bind(receipt_canonical)
    .bind(receipt_sha256)
    .bind(provider_turn_canonical)
    .bind(provider_turn_sha256)
    .bind(turn_transcript_sha256)
    .bind(input_units)
    .bind(output_units)
    .bind(provider_request_id_hash)
    .bind(cost_krw)
    .bind(error_code)
    .bind(error_sha256)
    .fetch_one(executor)
    .await
    .map_err(database)?;
    Ok(())
}

fn unknown_provider_receipt(
    run_id: Uuid,
    turn: &ProviderTurnIdentity,
    provider_config_id: Uuid,
    provider: &str,
    model: &str,
    semantic_request_sha256: &str,
    reason: &str,
) -> Result<(Uuid, Value), Failure> {
    let receipt_id = Uuid::new_v4();
    let observed_at = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|error| Failure::Terminal("PROVIDER_RECEIPT_INVALID", error.to_string()))?;
    let mut receipt = json!({
        "schemaVersion":"provider-receipt.v2",
        "receiptId":receipt_id,
        "agentRunId":run_id,
        "providerTurnId":turn.turn_id,
        "providerMode":"EXTERNAL_APPROVED",
        "providerConfigId":provider_config_id,
        "providerCandidateId":provider,
        "modelId":model,
        "modelConfigurationSha256":sha256(model.as_bytes()),
        "semanticRequestSha256":semantic_request_sha256,
        "idempotencyKeySha256":turn.idempotency_hash,
        "outcome":"OUTCOME_UNKNOWN",
        "proofKind":"IDEMPOTENCY_LOOKUP",
        "proofSha256":sha256(reason.as_bytes()),
        "providerRequestIdHash":null,
        "usage":{"state":"UNKNOWN","inputUnits":null,"outputUnits":null,"cachedInputUnits":null,"billableUnits":null,"usageEvidenceSha256":null},
        "pricing":{"pricingVersion":"unknown","pricingSha256":sha256(b"unknown-pricing"),"currency":"KRW","fxRateFactId":null,"reservedMicrosKrw":0,"actualMicrosKrw":null,"costState":"RECONCILIATION_REQUIRED"},
        "dataPolicy":{"classification":"INTERNAL","processingRegion":"ZZ","retentionMode":"ZERO_RETENTION","trainingUse":"PROHIBITED","policyVersion":"unknown","policySha256":sha256(b"unknown-policy"),"rightsDecisionSetSha256":sha256(b"unknown-rights")},
        "dispatchedAt":observed_at,
        "observedAt":observed_at,
        "completedAt":null
    });
    let receipt_sha256 = sha256(&canonical_bytes(&receipt)?);
    receipt["receiptSha256"] = json!(receipt_sha256);
    Ok((receipt_id, receipt))
}

#[expect(
    clippy::too_many_arguments,
    reason = "unknown-outcome reconciliation binds the original provider attempt"
)]
async fn mark_provider_turn_outcome_unknown(
    state: &State,
    turn: &ProviderTurnIdentity,
    run_id: Uuid,
    provider_config_id: Uuid,
    provider: &str,
    model: &str,
    semantic_request_sha256: &str,
    reason: &str,
) -> Result<(), Failure> {
    let (receipt_id, receipt) = unknown_provider_receipt(
        run_id,
        turn,
        provider_config_id,
        provider,
        model,
        semantic_request_sha256,
        reason,
    )?;
    let receipt_canonical = canonical_bytes(&receipt)?;
    let receipt_sha256 = sha256(&receipt_canonical);
    let turn_payload = json!({
        "providerTurnId":turn.turn_id,
        "status":"OUTCOME_UNKNOWN",
        "errorCode":"PROVIDER_OUTCOME_UNKNOWN",
        "providerReceiptSha256":receipt_sha256
    });
    let turn_canonical = canonical_bytes(&turn_payload)?;
    let turn_sha256 = sha256(&turn_canonical);
    let error_sha256 = sha256(b"PROVIDER_OUTCOME_UNKNOWN");
    complete_provider_turn_owner(
        &state.pool,
        turn,
        1,
        "OUTCOME_UNKNOWN",
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        receipt_id,
        &receipt,
        &receipt_canonical,
        &receipt_sha256,
        &turn_canonical,
        &turn_sha256,
        None,
        None,
        None,
        None,
        None,
        Some("PROVIDER_OUTCOME_UNKNOWN"),
        Some(&error_sha256),
    )
    .await
}
