#[expect(
    clippy::too_many_arguments,
    reason = "provider turn persistence records the immutable request provenance tuple"
)]
async fn insert_provider_turn(
    state: &State,
    run_id: Uuid,
    job_id: Uuid,
    case_id: Uuid,
    agent_type: &str,
    objective: &str,
    evidence: &Value,
    provider: &str,
    provider_config_id: Uuid,
    model: &str,
    routing_version: i64,
    input_snapshot_sha256: &str,
    maximum_cost_krw: i64,
    semantic_request_sha256: &str,
    environment: &str,
    turn_sequence: i32,
    prior_transcript_sha256: &str,
    prior_tool_result: Option<&Value>,
) -> Result<ProviderTurnIdentity, Failure> {
    let turn_id = Uuid::new_v4();
    let idempotency_hash = sha256(
        format!("agent-turn\0{run_id}\0{turn_sequence}\0{semantic_request_sha256}\0{model}")
            .as_bytes(),
    );
    if let Some(existing) = existing_provider_turn(state, run_id, &idempotency_hash).await? {
        return Ok(existing);
    }
    let request_data = build_provider_request(
        objective,
        evidence,
        semantic_request_sha256,
        turn_sequence,
        prior_transcript_sha256,
        prior_tool_result,
    )?;
    let request = request_data.request;
    let request_canonical = request_data.canonical;
    let request_sha256 = request_data.sha256;
    let policy = json!({"providerConfigId":provider_config_id,"version":routing_version});
    let model_configuration_sha256 = sha256(model.as_bytes());
    let routing_decision_sha256 = sha256(&canonical_bytes(&policy)?);
    let prompt_sha256 = sha256(agent_type.as_bytes());
    let output_schema_sha256 = sha256(b"gurine-agent-output-v1");
    let rights_sha256 = sha256(b"model-use-rights-required");
    sqlx::query_scalar::<_, Uuid>(
        "SELECT ops.start_agent_provider_turn(
           $1,$2,CAST($3 AS char(64)),CAST($28 AS integer),CAST($28 AS integer),CAST($4 AS char(64)),
           $5,$6,$7,CAST($8 AS char(64)),$9,CAST($10 AS char(64)),
           $11,$12,CAST($13 AS char(64)),$14,$15,CAST($16 AS char(64)),
           $17,CAST($18 AS char(64)),CAST($19 AS char(64)),CAST($20 AS char(64)),
           CAST($21 AS char(64)),$22,$23,$24,$25,$26,$27)",
    )
    .bind(turn_id)
    .bind(run_id)
    .bind(input_snapshot_sha256)
    .bind(prior_transcript_sha256)
    .bind(provider_config_id)
    .bind(provider)
    .bind(model)
    .bind(model_configuration_sha256)
    .bind(routing_version.to_string())
    .bind(routing_decision_sha256)
    .bind(agent_type)
    .bind("1")
    .bind(prompt_sha256)
    .bind("gurine-agent-output-v1")
    .bind("1")
    .bind(output_schema_sha256)
    .bind("INTERNAL")
    .bind(rights_sha256)
    .bind(sha256(
        format!("budget\0{run_id}\0{maximum_cost_krw}").as_bytes(),
    ))
    .bind(idempotency_hash.clone())
    .bind(request_sha256)
    .bind(&request)
    .bind(request_canonical)
    .bind(job_id)
    .bind(case_id)
    .bind(maximum_cost_krw)
    .bind(environment.to_ascii_uppercase())
    .bind(turn_sequence)
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    load_provider_turn_identity(state, turn_id, &idempotency_hash).await
}

struct ProviderRequestData {
    request: Value,
    canonical: Vec<u8>,
    sha256: String,
}

fn build_provider_request(
    objective: &str,
    evidence: &Value,
    semantic_request_sha256: &str,
    turn_sequence: i32,
    prior_transcript_sha256: &str,
    prior_tool_result: Option<&Value>,
) -> Result<ProviderRequestData, Failure> {
    let objective_sha256 = sha256(objective.as_bytes());
    let (ids, authorized_segment_count) = ordered_source_use_bindings(evidence)?;
    let ordered_source_use_ids = ids
        .into_iter()
        .map(|id| Value::String(id.to_string()))
        .collect::<Vec<_>>();
    let selected_content_refs = selected_content_capsule(evidence)?;
    let redaction_receipt_sha256 = sha256(&canonical_bytes(&json!({
        "objectiveSha256": objective_sha256,
        "semanticRequestSha256": semantic_request_sha256,
        "orderedSourceUseIds": ordered_source_use_ids.clone(),
        "authorizedSegmentCount": authorized_segment_count,
        "selectedContentRefs": selected_content_refs.clone()
    }))?);
    let request = json!({
        "schemaVersion":"agent-provider-request-redacted.v2",
        "objectiveSha256":objective_sha256,
        "messageCount":1,
        "turnSequence":turn_sequence,
        "priorTranscriptSha256":prior_transcript_sha256,
        "authorizedSegmentCount":authorized_segment_count,
        "orderedSourceUseIds":ordered_source_use_ids,
        "toolChoice":"AUTO_ALLOWLIST",
        "maxOutputUnits":131072,
        "semanticRequestSha256":semantic_request_sha256,
        "redactionReceiptSha256":redaction_receipt_sha256
    });
    let mut request = request;
    if let Some(tool_result) = prior_tool_result {
        request["priorToolResult"] = json!({
            "callId": tool_result.get("callId"),
            "response": tool_result.get("response"),
            "responseSha256": tool_result.get("responseSha256")
        });
    }
    request["redactionReceiptSha256"] = json!(sha256(&canonical_bytes(&json!({
        "objectiveSha256": objective_sha256,
        "semanticRequestSha256": semantic_request_sha256,
        "orderedSourceUseIds": request.get("orderedSourceUseIds").cloned().unwrap_or(Value::Array(Vec::new())),
        "authorizedSegmentCount": authorized_segment_count,
        "selectedContentRefs": selected_content_refs,
        "turnSequence": turn_sequence,
        "priorTranscriptSha256": prior_transcript_sha256,
        "priorToolResult": request.get("priorToolResult").cloned().unwrap_or(Value::Null)
    }))?));
    let canonical = canonical_bytes(&request)?;
    Ok(ProviderRequestData {
        sha256: sha256(&canonical),
        request,
        canonical,
    })
}

/// The database stores the closed `requestRedacted` contract. The gateway
/// additionally receives a short-lived capsule for resolving selected bytes.
async fn provider_wire_request(
    base: &Value,
    evidence: &Value,
    object_store: Option<&GatewayObjectStore>,
) -> Result<Value, Failure> {
    let mut object = base
        .as_object()
        .cloned()
        .ok_or_else(|| Failure::Terminal("PROVIDER_REQUEST_INVALID", "object".into()))?;
    let metadata = selected_content_capsule(evidence)?;
    let store = object_store.ok_or_else(|| {
        Failure::Terminal("OBJECT_STORE_EGRESS_MISSING", "selected source bytes".into())
    })?;
    let mut refs = Vec::with_capacity(metadata.len());
    for reference in metadata {
        let key = reference
            .get("selectedContentObjectKey")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "object key".into()))?;
        let digest = reference
            .get("selectedContentSha256")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "content digest".into()))?;
        let bytes = store
            .get(key, Some(digest))
            .await
            .map_err(|_| Failure::Terminal("OBJECT_STORE_READ_FAILED", key.to_owned()))?;
        let mut wire = reference
            .as_object()
            .cloned()
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "reference".into()))?;
        wire.remove("selectedContentObjectKey");
        wire.insert("selectedContentSizeBytes".into(), Value::from(bytes.len() as u64));
        wire.insert("selectedContentBytesBase64".into(), Value::String(BASE64.encode(bytes)));
        refs.push(Value::Object(wire));
    }
    object.insert("selectedContentRefs".to_owned(), Value::Array(refs));
    Ok(Value::Object(object))
}

fn selected_content_capsule(evidence: &Value) -> Result<Vec<Value>, Failure> {
    let rows = evidence
        .as_array()
        .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?;
    let mut refs = Vec::new();
    for row in rows {
        let uses = row
            .get("sourceUses")
            .and_then(Value::as_array)
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_MISSING", "sourceUses".into()))?;
        for source_use in uses {
            let source_use_id = source_use
                .get("sourceUseId")
                .and_then(Value::as_str)
                .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "sourceUseId".into()))?;
            let selected_sha = source_use
                .get("selectedContentSha256")
                .and_then(Value::as_str)
                .filter(|value| value.len() == 64)
                .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "selectedContentSha256".into()))?;
            let object_key = source_use
                .get("selectedContentObjectKey")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "selectedContentObjectKey".into()))?;
            let locator = source_use
                .get("selectedContentLocator")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "selectedContentLocator".into()))?;
            let media_type = source_use
                .get("selectedContentMediaType")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or("application/octet-stream");
            let rights = source_use
                .get("rightsDecision")
                .and_then(Value::as_object)
                .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_RIGHTS_MISSING", source_use_id.into()))?;
            refs.push(json!({
                "sourceUseId":source_use_id,
                "selectedContentSha256":selected_sha,
                "selectedContentObjectKey":object_key,
                "selectedContentLocator":locator,
                "selectedContentMediaType":media_type,
                "modelEgressRight":rights.get("modelEgressRight"),
                "modelUseRight":rights.get("modelUseRight"),
                "derivativeCreationRight":rights.get("derivativeCreationRight")
            }));
        }
    }
    if refs.is_empty() {
        return Err(Failure::Terminal(
            "AGENT_SOURCE_USE_MISSING",
            "selected content capsule empty".into(),
        ));
    }
    Ok(refs)
}

async fn load_provider_turn_identity(
    state: &State,
    turn_id: Uuid,
    idempotency_hash: &str,
) -> Result<ProviderTurnIdentity, Failure> {
    let row = sqlx::query(
        "SELECT provider_turn_id,agent_run_id,prior_transcript_sha256,input_snapshot_sha256,provider_config_id,
                provider_mode,provider_candidate_id,model_id,model_configuration_sha256,
                routing_policy_version,routing_decision_sha256,prompt_id,prompt_version,prompt_sha256,
                output_schema_id,output_schema_version,output_schema_sha256,classification,
                model_use_rights_sha256,budget_reservation_key_sha256,dispatch_key_sha256,request_sha256,
                request_redacted,turn_sequence,attempt_sequence,dispatched_at
           FROM ops.agent_provider_turns WHERE provider_turn_id=$1 AND dispatch_key_sha256=CAST($2 AS char(64))"
    )
    .bind(turn_id)
    .bind(idempotency_hash)
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    Ok(ProviderTurnIdentity {
        turn_id: row.try_get("provider_turn_id").map_err(database)?,
        run_id: row.try_get("agent_run_id").map_err(database)?,
        idempotency_hash: idempotency_hash.to_owned(),
        request_redacted: row.try_get("request_redacted").map_err(database)?,
        turn_sequence: row.try_get("turn_sequence").map_err(database)?,
        attempt_sequence: row.try_get("attempt_sequence").map_err(database)?,
        input_snapshot_sha256: row.try_get::<String, _>("input_snapshot_sha256").map_err(database)?,
        prior_transcript_sha256: row.try_get::<String, _>("prior_transcript_sha256").map_err(database)?,
        provider_config_id: row.try_get("provider_config_id").map_err(database)?,
        provider_mode: row.try_get("provider_mode").map_err(database)?,
        provider_candidate_id: row.try_get("provider_candidate_id").map_err(database)?,
        model_id: row.try_get("model_id").map_err(database)?,
        model_configuration_sha256: row.try_get::<String, _>("model_configuration_sha256").map_err(database)?,
        routing_policy_version: row.try_get("routing_policy_version").map_err(database)?,
        routing_decision_sha256: row.try_get::<String, _>("routing_decision_sha256").map_err(database)?,
        prompt_id: row.try_get("prompt_id").map_err(database)?,
        prompt_version: row.try_get("prompt_version").map_err(database)?,
        prompt_sha256: row.try_get::<String, _>("prompt_sha256").map_err(database)?,
        output_schema_id: row.try_get("output_schema_id").map_err(database)?,
        output_schema_version: row.try_get("output_schema_version").map_err(database)?,
        output_schema_sha256: row.try_get::<String, _>("output_schema_sha256").map_err(database)?,
        classification: row.try_get("classification").map_err(database)?,
        model_use_rights_sha256: row.try_get::<String, _>("model_use_rights_sha256").map_err(database)?,
        budget_reservation_key_sha256: row.try_get::<String, _>("budget_reservation_key_sha256").map_err(database)?,
        dispatch_key_sha256: row.try_get::<String, _>("dispatch_key_sha256").map_err(database)?,
        request_sha256: row.try_get::<String, _>("request_sha256").map_err(database)?,
        dispatched_at: row
            .try_get::<time::OffsetDateTime, _>("dispatched_at")
            .map_err(database)?
            .format(&time::format_description::well_known::Rfc3339)
            .map_err(|error| Failure::Terminal("PROVIDER_RECEIPT_INVALID", error.to_string()))?,
    })
}

async fn existing_provider_turn(
    state: &State,
    run_id: Uuid,
    idempotency_hash: &str,
) -> Result<Option<ProviderTurnIdentity>, Failure> {
    let Some(existing) = sqlx::query(
        "SELECT provider_turn_id,status FROM ops.agent_provider_turns
           WHERE agent_run_id=$1 AND dispatch_key_sha256=CAST($2 AS char(64))",
    )
    .bind(run_id)
    .bind(idempotency_hash)
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    else {
        return Ok(None);
    };
    let status: String = existing.try_get("status").map_err(database)?;
    if status != "DISPATCHED" {
        return Err(Failure::Retryable(
            "PROVIDER_OUTCOME_UNKNOWN",
            format!("provider turn already terminal: {status}"),
        ));
    }
    let turn_id = existing.try_get("provider_turn_id").map_err(database)?;
    Ok(Some(load_provider_turn_identity(state, turn_id, idempotency_hash).await?))
}
