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
    let classification = external_provider_classification(evidence)?;
    let turn_id = Uuid::new_v4();
    let idempotency_hash = sha256(
        format!("agent-turn\0{run_id}\0{turn_sequence}\0{semantic_request_sha256}\0{model}")
            .as_bytes(),
    );
    if let Some(existing) = existing_provider_turn(state, run_id, &idempotency_hash).await? {
        if existing.classification != classification {
            return Err(Failure::Terminal(
                "PROVIDER_TURN_CLASSIFICATION_MISMATCH",
                existing.turn_id.to_string(),
            ));
        }
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
    // Persist only the closed semantic request. Selected bytes are a short-lived gateway capsule,
    // reconstructed from the immutable snapshot before dispatch and never mixed into requestRedacted.
    let request_canonical = canonical_bytes(&request_data.request)?;
    let request_sha256 = sha256(&request_canonical);
    let policy = json!({"providerConfigId":provider_config_id,"version":routing_version});
    let model_configuration_sha256 = sha256(model.as_bytes());
    let routing_decision_sha256 = sha256(&canonical_bytes(&policy)?);
    // Bind the turn to authority-pinned prompt bytes; hashing the agent identifier would accept
    // prompt drift, so the registry is resolved from checked-in authority files at compile time.
    let (prompt_id, prompt_version, prompt_sha256) = pinned_prompt_contract(agent_type)
        .ok_or_else(|| Failure::Terminal("AGENT_REGISTRY_DRIFT", agent_type.to_owned()))?;
    let (output_schema_id, output_schema_version, output_schema_sha256) =
        output_schema_contract(agent_type);
    let rights_sha256 = model_use_rights_decision_set_sha256(evidence)?;
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
    .bind(prompt_id)
    .bind(prompt_version)
    .bind(prompt_sha256)
    .bind(output_schema_id)
    .bind(output_schema_version)
    .bind(output_schema_sha256)
    .bind(classification)
    .bind(rights_sha256)
    .bind(sha256(
        format!("budget\0{run_id}\0{maximum_cost_krw}").as_bytes(),
    ))
    .bind(idempotency_hash.clone())
    .bind(request_sha256)
    .bind(&request_data.request)
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

/// The addendum registry is intentionally closed: an unknown agent must fail
/// before egress rather than falling back to an arbitrary prompt hash.
fn pinned_prompt_contract(agent_type: &str) -> Option<(&'static str, &'static str, &'static str)> {
    match agent_type {
        "market-researcher" => Some((
            "market-researcher",
            "13.0.0+agent-multimodal.1",
            "d6cd7cff54efab4febf4673694b585cc74e74498b3820df7844887cca05f2c11",
        )),
        "investigator" => Some((
            "investigator",
            "13.0.0+agent-multimodal.1",
            "e7654bb7abf2cad997118ac649544ea20ef23ba1e7b5598df7ec45d54a9322f6",
        )),
        "skeptic" => Some((
            "skeptic",
            "13.0.0+agent-multimodal.1",
            "15f1a488f35bbd342e2d9ce8a8635cf7e720fccf459d7c46ee32faf3a6d4a9ef",
        )),
        "claim-drafter" => Some((
            "claim-drafter",
            "13.0.0+agent-multimodal.1",
            "302357154a51844bdf976a324640632d88d781cd14a0af6d309aa6deaf97c512",
        )),
        "citation-verifier" => Some((
            "citation-verifier",
            "13.0.0+agent-multimodal.1",
            "a97a37302de9e5a230f1f33ca580ddab49bb93b1ed899de72c275d7770c53492",
        )),
        _ => None,
    }
}

fn output_schema_contract(agent_type: &str) -> (&'static str, &'static str, &'static str) {
    match agent_type {
        "market-researcher" => (
            "MarketResearchOutputV2",
            "market-research-output.v2",
            "af49da181ef6e5bf37aa43245cd2ea44e2a71a1e41ac475e4f04c17137864577",
        ),
        "investigator" => (
            "InvestigatorOutputV2",
            "investigator-output.v2",
            "d1385cb045bfdffb8e49322019b735c5cf813e6207664c2ff8219f088b0c13df",
        ),
        "skeptic" => (
            "SkepticOutputV2",
            "skeptic-output.v2",
            "6df71038d32529334413d7c1757a67fc0c1eba9e19d8ea9bdb6ae5d1cd1197d1",
        ),
        "claim-drafter" => (
            "ClaimDraftOutputV2",
            "claim-draft-output.v2",
            "1b8118e9e01c6277863900f1bad315539a0618685ee431f1fa2ce181388272ec",
        ),
        "citation-verifier" => (
            "CitationVerificationOutputV2",
            "citation-verification-output.v2",
            "9a76c04dcbca76018b5dba2eb837a80fae3fbeb3360cba4e740913de0096be94",
        ),
        _ => (
            "InvestigatorOutputV2",
            "investigator-output.v2",
            "d1385cb045bfdffb8e49322019b735c5cf813e6207664c2ff8219f088b0c13df",
        ),
    }
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
    let prior_tool_result_sha256 = prior_tool_result
        .map(canonical_bytes)
        .transpose()?
        .map(|bytes| sha256(&bytes));
    let redaction_receipt_sha256 = sha256(&canonical_bytes(&json!({
        "objectiveSha256": objective_sha256,
        "semanticRequestSha256": semantic_request_sha256,
        "orderedSourceUseIds": ordered_source_use_ids.clone(),
        "authorizedSegmentCount": authorized_segment_count,
        "selectedContentRefs": selected_content_refs.clone(),
        "turnSequence": turn_sequence,
        "priorTranscriptSha256": prior_transcript_sha256,
        "priorToolResultSha256": prior_tool_result_sha256
    }))?);
    let request = json!({
        "schemaVersion":"agent-provider-request-redacted.v2",
        "objectiveSha256":objective_sha256,
        "messageCount":1,
        "authorizedSegmentCount":authorized_segment_count,
        "orderedSourceUseIds":ordered_source_use_ids,
        "toolChoice":"AUTO_ALLOWLIST",
        "maxOutputUnits":131072,
        "semanticRequestSha256":semantic_request_sha256,
        "redactionReceiptSha256":redaction_receipt_sha256
    });
    let mut request = request;
    request["redactionReceiptSha256"] = json!(sha256(&canonical_bytes(&json!({
        "objectiveSha256": objective_sha256,
        "semanticRequestSha256": semantic_request_sha256,
        "orderedSourceUseIds": request.get("orderedSourceUseIds").cloned().unwrap_or(Value::Array(Vec::new())),
        "authorizedSegmentCount": authorized_segment_count,
        "selectedContentRefs": selected_content_refs,
        "turnSequence": turn_sequence,
        "priorTranscriptSha256": prior_transcript_sha256,
        "priorToolResultSha256": prior_tool_result_sha256
    }))?));
    Ok(ProviderRequestData { request })
}

/// The database stores the closed `requestRedacted` contract. The gateway
/// additionally receives a short-lived capsule for resolving selected bytes.
async fn provider_wire_request(
    base: &Value,
    evidence: &Value,
    object_store: Option<&GatewayObjectStore>,
    pool: &sqlx::PgPool,
    objective: &str,
    prior_tool_result: Option<&Value>,
) -> Result<Value, Failure> {
    let mut object = base
        .as_object()
        .cloned()
        .ok_or_else(|| Failure::Terminal("PROVIDER_REQUEST_INVALID", "object".into()))?;
    let store = object_store.ok_or_else(|| {
        Failure::Terminal(
            "OBJECT_STORE_EGRESS_MISSING",
            "selected source bytes".into(),
        )
    })?;
    let mut refs = selected_content_wire_refs(evidence, store).await?;
    append_research_artifact_refs(&mut refs, prior_tool_result, store, pool).await?;
    object.insert("selectedContentRefs".to_owned(), Value::Array(refs));
    // The durable request remains redacted and hash-bound. The short-lived gateway capsule carries
    // the objective and prior tool result covered by the receipt, but never persists either value.
    object.insert("objective".to_owned(), Value::String(objective.to_owned()));
    if let Some(result) = prior_tool_result {
        object.insert("priorToolResult".to_owned(), result.clone());
    }
    Ok(Value::Object(object))
}

async fn selected_content_wire_refs(
    evidence: &Value,
    store: &GatewayObjectStore,
) -> Result<Vec<Value>, Failure> {
    let metadata = selected_content_capsule(evidence)?;
    let mut refs = Vec::with_capacity(metadata.len());
    for reference in metadata {
        let key = reference
            .get("selectedContentObjectKey")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "object key".into()))?;
        let digest = reference
            .get("selectedContentSha256")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                Failure::Terminal("AGENT_SOURCE_USE_INVALID", "content digest".into())
            })?;
        let bytes = store
            .get(key, Some(digest))
            .await
            .map_err(|_| Failure::Terminal("OBJECT_STORE_READ_FAILED", key.to_owned()))?;
        let mut wire = reference
            .as_object()
            .cloned()
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "reference".into()))?;
        wire.remove("selectedContentObjectKey");
        wire.insert(
            "selectedContentSizeBytes".into(),
            Value::from(bytes.len() as u64),
        );
        wire.insert(
            "selectedContentBytesBase64".into(),
            Value::String(BASE64.encode(bytes)),
        );
        refs.push(Value::Object(wire));
    }
    Ok(refs)
}

async fn append_research_artifact_refs(
    refs: &mut Vec<Value>,
    prior_tool_result: Option<&Value>,
    store: &GatewayObjectStore,
    pool: &sqlx::PgPool,
) -> Result<(), Failure> {
    let Some(result) = prior_tool_result else {
        return Ok(());
    };
    let artifacts = result
        .pointer("/response/artifacts")
        .or_else(|| result.pointer("/artifacts"))
        .and_then(Value::as_array)
        .map_or(&[][..], |value| value.as_slice());
    for artifact in artifacts {
        refs.push(research_artifact_wire_ref(artifact, store, pool).await?);
    }
    Ok(())
}

async fn research_artifact_wire_ref(
    artifact: &Value,
    store: &GatewayObjectStore,
    pool: &sqlx::PgPool,
) -> Result<Value, Failure> {
    let digest = artifact
        .get("contentSha256")
        .and_then(Value::as_str)
        .filter(|v| v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or_else(|| {
            Failure::Terminal("AGENT_RESEARCH_ARTIFACT_INVALID", "contentSha256".into())
        })?;
    let fetch_id = artifact
        .get("sourceFetchId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            Failure::Terminal("AGENT_RESEARCH_ARTIFACT_INVALID", "sourceFetchId".into())
        })?;
    let key: String = sqlx::query_scalar!(
        "SELECT object_key FROM raw.research_artifacts WHERE source_fetch_id=$1",
        fetch_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_RESEARCH_ARTIFACT_MISSING", fetch_id.to_string()))?;
    let bytes = store
        .get(&key, Some(digest))
        .await
        .map_err(|_| Failure::Terminal("OBJECT_STORE_READ_FAILED", key))?;
    let mut wire = serde_json::Map::new();
    for field in [
        "researchArtifactId",
        "assetId",
        "assetRevision",
        "sourceFetchId",
        "artifactOrdinal",
        "sourceAuthority",
        "finalOrigin",
        "retrievedAt",
        "httpStatus",
        "contentMediaType",
        "contentSizeBytes",
        "contentSha256",
        "artifactSha256",
        "sourceUseId",
        "sourceUseSha256",
    ] {
        if let Some(value) = artifact.get(field) {
            wire.insert(field.to_owned(), value.clone());
        }
    }
    wire.insert(
        "selectedContentSizeBytes".into(),
        Value::from(bytes.len() as u64),
    );
    wire.insert(
        "selectedContentBytesBase64".into(),
        Value::String(BASE64.encode(bytes)),
    );
    wire.insert(
        "selectedContentSha256".into(),
        Value::String(digest.to_owned()),
    );
    Ok(Value::Object(wire))
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
            refs.push(selected_content_reference(source_use)?);
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

fn selected_content_reference(source_use: &Value) -> Result<Value, Failure> {
    let source_use_id = source_use
        .get("sourceUseId")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "sourceUseId".into()))?;
    let source_use_sha = source_use
        .get("sourceUseSha256")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64)
        .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "sourceUseSha256".into()))?;
    let selected_sha = source_use
        .get("selectedContentSha256")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64)
        .ok_or_else(|| {
            Failure::Terminal("AGENT_SOURCE_USE_INVALID", "selectedContentSha256".into())
        })?;
    let object_key = source_use
        .get("selectedContentObjectKey")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            Failure::Terminal(
                "AGENT_SOURCE_USE_INVALID",
                "selectedContentObjectKey".into(),
            )
        })?;
    let locator = source_use
        .get("selectedContentLocator")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            Failure::Terminal("AGENT_SOURCE_USE_INVALID", "selectedContentLocator".into())
        })?;
    let media_type = source_use
        .get("selectedContentMediaType")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("application/octet-stream");
    let rights = source_use
        .get("rightsDecision")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            Failure::Terminal("AGENT_SOURCE_USE_RIGHTS_MISSING", source_use_id.into())
        })?;
    let locator_sha = source_use
        .pointer("/locator/sha256")
        .or_else(|| source_use.pointer("/locator/locatorSha256"))
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64)
        .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "locatorSha256".into()))?;
    Ok(json!({
        "sourceUseId":source_use_id,
        "sourceUseSha256":source_use_sha,
        "selectedContentSha256":selected_sha,
        "selectedContentObjectKey":object_key,
        "selectedContentLocator":locator,
        "selectedContentMediaType":media_type,
        "locatorSha256":locator_sha,
        "modelEgressRight":rights.get("modelEgressRight"),
        "modelUseRight":rights.get("modelUseRight"),
        "derivativeCreationRight":rights.get("derivativeCreationRight")
    }))
}

async fn load_provider_turn_identity(
    state: &State,
    turn_id: Uuid,
    idempotency_hash: &str,
) -> Result<ProviderTurnIdentity, Failure> {
    let row = sqlx::query!(
        "SELECT t.provider_turn_id,t.agent_run_id,t.prior_transcript_sha256,t.input_snapshot_sha256,t.provider_config_id,
                t.provider_mode,t.provider_candidate_id,t.model_id,t.model_configuration_sha256,
                t.routing_policy_version,t.routing_decision_sha256,t.prompt_id,t.prompt_version,t.prompt_sha256,
                t.output_schema_id,t.output_schema_version,t.output_schema_sha256,t.classification,
                t.model_use_rights_sha256,t.budget_reservation_key_sha256,t.dispatch_key_sha256,t.request_sha256,
                t.request_redacted,t.turn_sequence,t.attempt_sequence,t.dispatched_at,r.dataset_snapshot_id
           FROM ops.agent_provider_turns t
           JOIN ops.agent_runs r ON r.id=t.agent_run_id
          WHERE t.provider_turn_id=$1 AND t.dispatch_key_sha256=CAST($2 AS char(64))"
        ,
        turn_id,
        idempotency_hash,
    )
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    Ok(ProviderTurnIdentity {
        turn_id: row.provider_turn_id,
        run_id: row.agent_run_id,
        idempotency_hash: idempotency_hash.to_owned(),
        request_redacted: row.request_redacted,
        dataset_snapshot_id: row.dataset_snapshot_id,
        turn_sequence: row.turn_sequence,
        attempt_sequence: row.attempt_sequence,
        input_snapshot_sha256: row.input_snapshot_sha256,
        prior_transcript_sha256: row.prior_transcript_sha256,
        provider_config_id: required(row.provider_config_id).map_err(database)?,
        provider_mode: row.provider_mode,
        provider_candidate_id: row.provider_candidate_id,
        model_id: row.model_id,
        model_configuration_sha256: row.model_configuration_sha256,
        routing_policy_version: row.routing_policy_version,
        routing_decision_sha256: row.routing_decision_sha256,
        prompt_id: row.prompt_id,
        prompt_version: row.prompt_version,
        prompt_sha256: row.prompt_sha256,
        output_schema_id: row.output_schema_id,
        output_schema_version: row.output_schema_version,
        output_schema_sha256: row.output_schema_sha256,
        classification: row.classification,
        model_use_rights_sha256: row.model_use_rights_sha256,
        budget_reservation_key_sha256: row.budget_reservation_key_sha256,
        dispatch_key_sha256: row.dispatch_key_sha256,
        request_sha256: row.request_sha256,
        dispatched_at: row
            .dispatched_at
            .format(&time::format_description::well_known::Rfc3339)
            .map_err(|error| Failure::Terminal("PROVIDER_RECEIPT_INVALID", error.to_string()))?,
    })
}

async fn existing_provider_turn(
    state: &State,
    run_id: Uuid,
    idempotency_hash: &str,
) -> Result<Option<ProviderTurnIdentity>, Failure> {
    let Some(existing) = sqlx::query!(
        "SELECT provider_turn_id,status FROM ops.agent_provider_turns
           WHERE agent_run_id=$1 AND dispatch_key_sha256=CAST($2 AS char(64))",
        run_id,
        idempotency_hash,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    else {
        return Ok(None);
    };
    let status = existing.status;
    if status != "DISPATCHED" {
        return Err(Failure::Retryable(
            "PROVIDER_OUTCOME_UNKNOWN",
            format!("provider turn already terminal: {status}"),
        ));
    }
    let turn_id = existing.provider_turn_id;
    Ok(Some(
        load_provider_turn_identity(state, turn_id, idempotency_hash).await?,
    ))
}

#[cfg(test)]
mod tests {
    use super::pinned_prompt_contract;

    #[test]
    fn authority_prompt_registry_is_closed_and_pinned() {
        let expected = [
            (
                "market-researcher",
                "d6cd7cff54efab4febf4673694b585cc74e74498b3820df7844887cca05f2c11",
            ),
            (
                "investigator",
                "e7654bb7abf2cad997118ac649544ea20ef23ba1e7b5598df7ec45d54a9322f6",
            ),
            (
                "skeptic",
                "15f1a488f35bbd342e2d9ce8a8635cf7e720fccf459d7c46ee32faf3a6d4a9ef",
            ),
            (
                "claim-drafter",
                "302357154a51844bdf976a324640632d88d781cd14a0af6d309aa6deaf97c512",
            ),
            (
                "citation-verifier",
                "a97a37302de9e5a230f1f33ca580ddab49bb93b1ed899de72c275d7770c53492",
            ),
        ];
        for (agent, digest) in expected {
            let (id, version, actual) = pinned_prompt_contract(agent).expect("pinned agent");
            assert_eq!(id, agent);
            assert_eq!(version, "13.0.0+agent-multimodal.1");
            assert_eq!(actual, digest);
        }
        assert!(pinned_prompt_contract("unknown").is_none());
    }
}
