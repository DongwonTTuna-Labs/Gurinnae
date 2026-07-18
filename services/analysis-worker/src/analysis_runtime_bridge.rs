/// The HTTP gateway is the transport boundary.  The bridge decodes the
/// provider envelope into the closed Rust runtime types and executes internal
/// tools against the same immutable evidence snapshot used by the request.
fn validate_typed_provider_output(
    turn: &ProviderTurnIdentity,
    output: &Value,
    actual_cost_krw: i64,
) -> Result<(), Failure> {
    let final_output = typed_final_output(output)?;
    let cost_micros = u64::try_from(actual_cost_krw)
        .ok()
        .and_then(|value| value.checked_mul(1_000_000))
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "runtime cost".into()))?;
    let provider = ExternalFinalProvider {
        output: final_output,
        cost_micros,
    };
    let runtime = MultiTurnRuntime {
        provider,
        tools: TypedDispatcher::new(),
    };
    let budget = cost_micros.max(1);
    let config = MultiTurnConfig {
        max_provider_turns: 1,
        max_tool_calls: 0,
        budget_micros_krw: budget,
        worst_case_turn_cost_micros_krw: budget,
    };
    let outcome = runtime
        .run(
            &turn.prompt_id,
            turn.turn_id,
            turn.input_snapshot_sha256.clone(),
            turn.request_sha256.clone(),
            config,
        )
        .map_err(|error| Failure::Terminal("AGENT_RUNTIME_INVALID", error.to_string()))?;
    match outcome {
        gurine_agent_orchestration::runtime::RunOutcome::Succeeded { .. }
        | gurine_agent_orchestration::runtime::RunOutcome::Abstained { .. } => Ok(()),
        gurine_agent_orchestration::runtime::RunOutcome::BudgetBlocked { .. }
        | gurine_agent_orchestration::runtime::RunOutcome::ReconciliationRequired { .. } => {
            Err(Failure::Retryable(
                "AGENT_RUNTIME_NOT_TERMINAL",
                turn.turn_id.to_string(),
            ))
        }
    }
}

fn typed_final_output(value: &Value) -> Result<AgentFinalOutput, Failure> {
    let status = match value.get("status").and_then(Value::as_str) {
        Some("COMPLETED") => FinalStatus::Completed,
        Some("ABSTAINED" | "POLICY_BLOCKED" | "BUDGET_BLOCKED") => FinalStatus::Abstained,
        _ => return Err(Failure::Terminal("AGENT_RUNTIME_INVALID", "status".into())),
    };
    let summary = value
        .get("summary")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .ok_or_else(|| Failure::Terminal("AGENT_RUNTIME_INVALID", "summary".into()))?
        .to_owned();
    Ok(AgentFinalOutput {
        status,
        summary,
        citations: typed_citations(value),
    })
}

fn typed_citations(value: &Value) -> Vec<gurine_agent_orchestration::runtime::Citation> {
    value
        .get("citations")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let source_use_id = item
                .get("source_use_id")
                .or_else(|| item.get("sourceUseId"))
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())?;
            let selected_content_sha256 = item
                .get("selected_content_sha256")
                .or_else(|| item.get("selectedContentSha256"))
                .and_then(Value::as_str)
                .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))?
                .to_owned();
            Some(gurine_agent_orchestration::runtime::Citation {
                source_use_id,
                selected_content_sha256,
            })
        })
        .collect()
}

struct ExternalFinalProvider {
    output: AgentFinalOutput,
    cost_micros: u64,
}

fn parse_tool_call(
    body: &Value,
    turn: &ProviderTurnIdentity,
    _evidence: &Value,
) -> Result<gurine_agent_orchestration::runtime::ToolCall, Failure> {
    let envelope = body
        .get("toolCall")
        .or_else(|| body.get("tool_call"))
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "toolCall".into()))?;
    let object = envelope
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "object".into()))?;
    let call_id = object
        .get("callId")
        .or_else(|| object.get("call_id"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= 64)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "callId".into()))?;
    let tool_id = object
        .get("toolId")
        .or_else(|| object.get("tool_id"))
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "toolId".into()))?;
    let mut arguments = object
        .get("request")
        .or_else(|| object.get("arguments"))
        .cloned()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request".into()))?;
    let binding = json!({
        "run_id": turn.run_id,
        "input_snapshot_id": stable_uuid(turn.input_snapshot_sha256.as_bytes()),
        "input_snapshot_sha256": turn.input_snapshot_sha256
    });
    if let Some(map) = arguments.as_object_mut() {
        map.insert("binding".to_owned(), binding);
    }
    let request = decode_tool_request(tool_id, arguments)?;
    let request_sha256 = sha256(
        &serde_json::to_vec(&request)
            .map_err(|error| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", error.to_string()))?,
    );
    if let Some(expected) = object
        .get("requestSha256")
        .or_else(|| object.get("argumentsSha256"))
        .and_then(Value::as_str)
        && expected != request_sha256
    {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "requestSha256".into()));
    }
    Ok(gurine_agent_orchestration::runtime::ToolCall {
        call_id: stable_uuid(call_id.as_bytes()),
        request,
        request_sha256,
    })
}

fn decode_tool_request(
    tool_id: &str,
    arguments: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    macro_rules! decode { ($variant:ident) => { serde_json::from_value(arguments).map(gurine_agent_orchestration::runtime::ToolRequest::$variant).map_err(tool_decode) }; }
    match tool_id {
        "claim.language_check" => decode!(ClaimLanguageCheck),
        "contract.find_comparables" => decode!(ContractFindComparables),
        "entity.lookup" => decode!(EntityLookup),
        "evidence.read" => decode!(EvidenceRead),
        "evidence.search" => decode!(EvidenceSearch),
        "response.read" => decode!(ResponseRead),
        "rule.reproduce" => decode!(RuleReproduce),
        "source.fetch" => decode!(SourceFetch),
        "source.locator_verify" => decode!(SourceLocatorVerify),
        _ => Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "toolId".into())),
    }
}

fn tool_decode(error: serde_json::Error) -> Failure {
    Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", error.to_string())
}

async fn dispatch_tool_call(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    call: gurine_agent_orchestration::runtime::ToolCall,
    receipt: &Value,
) -> Result<(Value, String), Failure> {
    use gurine_agent_orchestration::runtime::{
        ComparableRecord, EntityRecord, ResponseRecord, RuleRecord,
        SourceArtifactRecord, SnapshotBinding, ToolSnapshot, TypedDispatcher,
    };
    let binding = SnapshotBinding {
        run_id: turn.run_id,
        input_snapshot_id: stable_uuid(turn.input_snapshot_sha256.as_bytes()),
        input_snapshot_sha256: turn.input_snapshot_sha256.clone(),
    };
    let evidence = evidence_records(state, turn).await?;
    let dispatcher = TypedDispatcher::from_snapshot(ToolSnapshot {
        binding,
        evidence,
        responses: Vec::<ResponseRecord>::new(),
        comparables: Vec::<ComparableRecord>::new(),
        entities: Vec::<EntityRecord>::new(),
        rules: Vec::<RuleRecord>::new(),
        source_artifacts: Vec::<SourceArtifactRecord>::new(),
    });
    let response = dispatcher
        .dispatch(agent_type, &call.request)
        .map_err(|error| Failure::Terminal("AGENT_TOOL_DENIED", error.to_string()))?;
    let response_json = serde_json::to_value(&response)
        .map_err(|error| Failure::Terminal("AGENT_TOOL_RESULT_INVALID", error.to_string()))?;
    let result_sha256 = sha256(
        &serde_json::to_vec(&response)
            .map_err(|error| Failure::Terminal("AGENT_TOOL_RESULT_INVALID", error.to_string()))?,
    );
    let transcript = json!({
        "priorTranscriptSha256": turn.prior_transcript_sha256,
        "providerTurnId": turn.turn_id,
        "callId": call.call_id,
        "requestSha256": call.request_sha256,
        "resultSha256": result_sha256,
        "providerReceiptSha256": sha256(&canonical_bytes(receipt)?),
    });
    let transcript_sha256 = sha256(&canonical_bytes(&transcript)?);
    let result = json!({
        "callId": call.call_id,
        "response": response_json,
        "responseSha256": result_sha256,
    });
    persist_tool_call(state, turn, agent_type, &call, &result, &transcript_sha256).await?;
    Ok((result, transcript_sha256))
}

async fn evidence_records(state: &State, turn: &ProviderTurnIdentity) -> Result<Vec<gurine_agent_orchestration::runtime::EvidenceRecord>, Failure> {
    let rows = sqlx::query(
        "SELECT e.id, su.source_use_id, btrim(su.selected_content_sha256::text) AS selected_sha, COALESCE(su.locator_value,e.source_locator) AS locator
           FROM editorial.evidence e
           JOIN ops.agent_source_uses su ON su.agent_run_id=$1 AND su.use_kind='TOOL_QUERY' AND su.source_kind='DATASET_MEMBER'
          WHERE e.verification_status='VERIFIED' AND su.selected_content_sha256 IS NOT NULL
          ORDER BY e.id, su.source_use_id",
    )
    .bind(turn.run_id)
    .fetch_all(&state.pool)
    .await
    .map_err(database)?;
    rows.into_iter()
        .map(|row| Ok(gurine_agent_orchestration::runtime::EvidenceRecord {
            evidence_id: row.try_get("id").map_err(database)?,
            source_use_id: row.try_get("source_use_id").map_err(database)?,
            selected_content_sha256: row.try_get("selected_sha").map_err(database)?,
            locator: row.try_get("locator").map_err(database)?,
        }))
        .collect()
}

async fn persist_tool_call(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    result: &Value,
    transcript_sha256: &str,
) -> Result<(), Failure> {
    let request = serde_json::to_value(&call.request)
        .map_err(|error| Failure::Terminal("AGENT_TOOL_REQUEST_INVALID", error.to_string()))?;
    let request_canonical = serde_json::to_vec(&request)
        .map_err(|error| Failure::Terminal("AGENT_TOOL_REQUEST_INVALID", error.to_string()))?;
    let result_canonical = canonical_bytes(result)?;
    let request_sha256 = sha256(&request_canonical);
    let result_sha256 = sha256(&result_canonical);
    let tool_id = call.request.tool_id().wire_name();
    let (request_schema_sha256, response_schema_sha256) = tool_schema_hashes(tool_id);
    let call_text = call.call_id.to_string();
    let tool_call_id = Uuid::new_v4();
    let now = time::OffsetDateTime::now_utc();
    let lease_expires = now + time::Duration::seconds(60);
    sqlx::query(
        "INSERT INTO ops.agent_tool_calls(
           tool_call_id,agent_run_id,provider_turn_id,call_id,input_snapshot_sha256,
           prior_transcript_sha256,tool_id,tool_catalog_version,tool_catalog_sha256,
           request_schema_id,request_schema_version,request_schema_sha256,response_schema_id,
           response_schema_version,response_schema_sha256,timeout_ms,max_results,request_sha256,
           request_redacted,request_canonical,allowlist_decision_sha256,scope_decision_sha256,
           rights_decision_sha256,classification,status,result_kind,result_sha256,result_redacted,
           result_canonical,response_validation_sha256,result_transcript_sha256,source_use_count,
           source_use_set_sha256,latency_ms,claim_generation,lease_token_sha256,lease_expires_at,
           version,started_at,terminal_at)
         VALUES($1,$2,$3,$4,$5,$6,$7,'13.0.0+agent-multimodal.1',$8,
           $9,'2',$10,$11,'2',$12,30000,50,$13,$14,$15,$16,$17,$18,'INTERNAL',
           'SUCCEEDED','TOOL_RESULT',$19,$20,$21,$22,$23,0,
           '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',0,1,$24,$25,1,$26,$26)
         ON CONFLICT(agent_run_id,call_id) DO NOTHING",
    )
    .bind(tool_call_id)
    .bind(turn.run_id)
    .bind(turn.turn_id)
    .bind(&call_text)
    .bind(&turn.input_snapshot_sha256)
    .bind(&turn.prior_transcript_sha256)
    .bind(tool_id)
    .bind(sha256(b"tool-catalog-v2"))
    .bind(format!("{tool_id}.request.v2"))
    .bind(request_schema_sha256)
    .bind(format!("{tool_id}.response.v2"))
    .bind(response_schema_sha256)
    .bind(request_sha256)
    .bind(request)
    .bind(request_canonical)
    .bind(sha256(format!("allowlist:{agent_type}").as_bytes()))
    .bind(sha256(b"snapshot-scope"))
    .bind(sha256(b"rights-allow"))
    .bind(&result_sha256)
    .bind(result)
    .bind(result_canonical)
    .bind(sha256(b"response-valid"))
    .bind(transcript_sha256)
    .bind(sha256(call_text.as_bytes()))
    .bind(lease_expires)
    .bind(now)
    .execute(&state.pool)
    .await
    .map_err(database)?;
    insert_tool_result_source_uses(state, turn, tool_call_id, tool_id, result_sha256.as_str()).await?;
    let summary = sqlx::query(
        "SELECT count(*)::int AS count, encode(extensions.digest(convert_to(array_to_string(array_agg(source_use_sha256::text ORDER BY source_use_sha256),','),'UTF8'),'sha256'),'hex') AS digest\n         FROM ops.agent_source_uses WHERE agent_run_id=$1 AND tool_call_id=$2 AND use_kind='TOOL_RESULT'",
    )
    .bind(turn.run_id)
    .bind(tool_call_id)
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    let source_use_count: i32 = summary.try_get("count").map_err(database)?;
    let source_use_set_sha256: String = summary.try_get("digest").map_err(database)?;
    sqlx::query("SELECT ops.finalize_agent_tool_call_source_uses($1,$2,CAST($3 AS char(64)))")
        .bind(tool_call_id)
        .bind(source_use_count)
        .bind(source_use_set_sha256)
        .execute(&state.pool)
        .await
        .map_err(database)?;
    Ok(())
}

/// A tool result is a provenance edge from every source selected by the
/// initial TOOL_QUERY receipt.  The child preserves the exact snapshot/member,
/// locator and rights tuple and adds the provider turn/tool-call binding; no
/// source identity is reconstructed from an editorial evidence row.
async fn insert_tool_result_source_uses(
    state: &State,
    turn: &ProviderTurnIdentity,
    tool_call_id: Uuid,
    tool_id: &str,
    result_sha256: &str,
) -> Result<(), Failure> {
    sqlx::query(
        r#"
        WITH parents AS (
          SELECT * FROM ops.agent_source_uses
           WHERE agent_run_id=$1 AND use_kind='TOOL_QUERY'
        ), identities AS (
          SELECT p.*, gen_random_uuid() AS new_source_use_id, clock_timestamp() AS new_occurred_at
            FROM parents p
        ), unsigned AS (
          SELECT i.*, jsonb_build_object(
            'schemaVersion','source-use.v2','sourceUseId',i.new_source_use_id,
            'agentRunId',i.agent_run_id,'providerTurnId',$2,'toolCallId',$3,
            'parentSourceUseId',i.source_use_id,'parentSourceUseSha256',btrim(i.source_use_sha256::text),
            'useKind','TOOL_RESULT','sourceKind',i.source_kind,
            'toolId',$4,'resultSha256',$5,
            'selectedContentSha256',btrim(i.selected_content_sha256::text),
            'locator',jsonb_build_object('kind',i.locator_kind,'value',i.locator_value,'locatorSha256',btrim(i.locator_sha256::text)),
            'classification',i.classification,
            'providerReceiptId',NULL,'occurredAt',i.new_occurred_at
          ) AS payload
          FROM identities i
        ), payloads AS (
          SELECT u.*, encode(extensions.digest(convert_to(u.payload::text,'UTF8'),'sha256'),'hex') AS digest
            FROM unsigned u
        )
        INSERT INTO ops.agent_source_uses(
          source_use_id,source_use_contract_version,agent_run_id,provider_turn_id,tool_call_id,
          parent_source_use_id,parent_source_use_sha256,use_kind,source_kind,
          dataset_snapshot_id,snapshot_member_id,snapshot_member_digest,snapshot_member_source_id,
          snapshot_member_source_digest,member_source_kind,object_type,object_id,object_version,
          object_content_sha256,evidence_segment_id,source_document_id,source_asset_id,
          source_asset_revision,source_content_sha256,response_id,response_version,response_content_sha256,
          response_publication_consent_sha256,research_artifact_id,research_asset_id,research_asset_revision,
          research_artifact_sha256,research_content_sha256,research_source_fetch_id,locator_kind,locator_value,
          locator_sha256,selected_content_sha256,classification,rights_binding_kind,rights_asset_id,
          rights_asset_revision,rights_asset_sha256,asset_rights_decision_id,asset_rights_decision_version,
          asset_rights_decision_sha256,rights_effective_at,rights_expires_at,access_right,private_storage_right,
          model_egress_right,model_use_right,derivative_creation_right,excerpt_right,redistribution_right,
          commercial_use_right,public_display_right,rights_policy_version,rights_policy_sha256,
          provider_receipt_id,provider_receipt_sha256,occurred_at,source_use_canonical,source_use_sha256)
        SELECT p.new_source_use_id,2,p.agent_run_id,$2,$3,
          p.source_use_id,p.source_use_sha256,'TOOL_RESULT',p.source_kind,
          p.dataset_snapshot_id,p.snapshot_member_id,p.snapshot_member_digest,p.snapshot_member_source_id,
          p.snapshot_member_source_digest,p.member_source_kind,p.object_type,p.object_id,p.object_version,
          p.object_content_sha256,p.evidence_segment_id,p.source_document_id,p.source_asset_id,
          p.source_asset_revision,p.source_content_sha256,p.response_id,p.response_version,p.response_content_sha256,
          p.response_publication_consent_sha256,p.research_artifact_id,p.research_asset_id,p.research_asset_revision,
          p.research_artifact_sha256,p.research_content_sha256,p.research_source_fetch_id,p.locator_kind,p.locator_value,
          p.locator_sha256,p.selected_content_sha256,p.classification,p.rights_binding_kind,p.rights_asset_id,
          p.rights_asset_revision,p.rights_asset_sha256,p.asset_rights_decision_id,p.asset_rights_decision_version,
          p.asset_rights_decision_sha256,p.rights_effective_at,p.rights_expires_at,p.access_right,p.private_storage_right,
          p.model_egress_right,p.model_use_right,p.derivative_creation_right,p.excerpt_right,p.redistribution_right,
          p.commercial_use_right,p.public_display_right,p.rights_policy_version,p.rights_policy_sha256,
          NULL,NULL,p.new_occurred_at,
          convert_to((p.payload || jsonb_build_object('sourceUseSha256',p.digest))::text,'UTF8'),p.digest
        FROM payloads p
        ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
        "#,
    )
    .bind(turn.run_id)
    .bind(turn.turn_id)
    .bind(tool_call_id)
    .bind(tool_id)
    .bind(result_sha256)
    .execute(&state.pool)
    .await
    .map_err(database)?;
    Ok(())
}

fn tool_schema_hashes(tool_id: &str) -> (&'static str, &'static str) {
    match tool_id {
        "claim.language_check" => ("0eff4fa492ebc9664f49ecf871880c7f776050c36e9d4ddac1a3d4482600e615", "ac77f413e976813197b57db66a5737178c87f51ba7d67b19bc31aa80b7c0dbf6"),
        "contract.find_comparables" => ("84fc62d88f8c6d61717fcf7e025cc4e7b4825703cb147d207ba6a92d8875a5c0", "15f512d7b8d1ddb98c09e04ece72c0907e29c21a38501bb539d86e43881e64fe"),
        "entity.lookup" => ("19133149878dbbf54ef7865f1822c77ea2c31aac8bcfcc377ad4869e18bb713d", "0dc88f3b5cac41877326f3f6cbf5a86a8859e4124bdc387adc7816c3444256a1"),
        "evidence.read" => ("71ba7e5b3d0867e7ac36354f82d42cf8533c1ed93b49426f248cc9147a6b8bde", "ec19aa983c3c786da78f4e2bc41e6398c6af24ae8d3506ee4cf0848a4a0fa4e0"),
        "evidence.search" => ("d92f236d62ab15ddb3ba12af5f63079e2293057d7d5d21f5d43280306ca54c42", "cc44ee052c404fae5fd5945e483d60966e76b1f44c1ebfea576b19444bc651ca"),
        "response.read" => ("87e0332aed2c7de8f604db95a629159856426e3f8e4f2649194c5148716d74ee", "f751a34a8f78407894ff96605241928d3fecee2f7ff9b48ba130ecb48701855f"),
        "rule.reproduce" => ("ba0e45b6c03dad44a99299fc5a06058e740500dabe60f6af13cc77ebc5fd4147", "8104f45d77b0d576e986844e09b34370c642042ebe8d7c8a8dc3d68fbf9b21ff"),
        "source.fetch" => ("8a6083ee948e416f71d7ee7e34ddb6ca41e84a8e3a2d1be53c4900605dc80c67", "42e59f2ddbe8bf2c58e61451cd698e388463f42bcdc13394bb6bf5140ca5912e"),
        _ => ("3470624bf89ed5d2116d7ef365b4dd017e822736f5b8d71189c7312653a5512f", "d8ddd0649eb49c0f0d8bc9490fb48134cb383cfa671d53d6ad710be39bd998ad"),
    }
}

fn stable_uuid(seed: &[u8]) -> Uuid {
    let digest = Sha256::digest(seed);
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

impl ProviderAdapter for ExternalFinalProvider {
    fn complete(&self, request: &ProviderRequest) -> Result<ProviderReply, ProviderRuntimeError> {
        let request_sha256 = provider_request_sha256(request)
            .map_err(|_| ProviderRuntimeError::InvalidReceipt)?;
        let mut receipt = ProviderReceipt {
            idempotency_key: request.idempotency_key.clone(),
            request_sha256,
            outcome: ProviderOutcome::FinalAccepted,
            cost_micros_krw: self.cost_micros,
            receipt_sha256: String::new(),
        };
        receipt.receipt_sha256 = provider_receipt_sha256(&receipt)
            .map_err(|_| ProviderRuntimeError::InvalidReceipt)?;
        Ok(ProviderReply {
            envelope: ProviderEnvelope::FinalOutput(self.output.clone()),
            receipt,
        })
    }
}
