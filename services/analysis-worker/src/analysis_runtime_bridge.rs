mod analysis_source_fetch;
mod analysis_tool_dispatch;
mod analysis_tool_persistence;
use analysis_source_fetch::{PendingSourceFetch, persist_research_fetch};
use analysis_tool_dispatch::{DispatchedTool, execute_tool, tool_result_and_transcript};

/// The HTTP gateway is the transport boundary. The bridge decodes the
/// provider envelope into the closed Rust runtime types and executes internal
/// tools against the same immutable evidence snapshot used by the request.
async fn validate_typed_provider_output(
    state: &State,
    turn: &ProviderTurnIdentity,
    output: &Value,
    actual_cost_krw: i64,
) -> Result<(), Failure> {
    let binding = SnapshotBinding {
        run_id: turn.run_id,
        input_snapshot_id: resolve_snapshot_id(state, turn).await?,
        input_snapshot_sha256: turn.input_snapshot_sha256.clone(),
    };
    let snapshot = analysis_runtime_snapshot::load_tool_snapshot(state, turn, binding).await?;
    let final_output = typed_final_output(output, &snapshot.evidence)?;
    let cost_micros = u64::try_from(actual_cost_krw)
        .ok()
        .and_then(|value| value.checked_mul(1_000_000))
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "runtime cost".into()))?;
    let provider = ExternalFinalProvider {
        output: final_output,
        cost_micros,
    };
    if provider.output.citations.iter().any(|citation| {
        !snapshot.evidence.iter().any(|evidence| {
            evidence.source_use_id == citation.source_use_id
                && evidence.selected_content_sha256 == citation.selected_content_sha256
        })
    }) {
        return Err(Failure::Terminal(
            "AGENT_RUNTIME_INVALID",
            "citation is not present in the repeatable-read source snapshot".into(),
        ));
    }
    let dispatcher = TypedDispatcher::from_snapshot(snapshot);
    let runtime = MultiTurnRuntime {
        provider,
        tools: dispatcher,
    };
    let budget = cost_micros.max(1);
    let (max_provider_turns, max_tool_calls) = runtime_bounds(&turn.output_schema_id);
    let config = MultiTurnConfig {
        max_provider_turns,
        max_tool_calls,
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
        | gurine_agent_orchestration::runtime::RunOutcome::ReconciliationRequired { .. } => Err(
            Failure::Retryable("AGENT_RUNTIME_NOT_TERMINAL", turn.turn_id.to_string()),
        ),
    }
}
fn runtime_bounds(output_schema_id: &str) -> (u16, u16) {
    match output_schema_id {
        "MarketResearchOutputV2" => (12, 11),
        "InvestigatorOutputV2" => (16, 15),
        "SkepticOutputV2" => (12, 11),
        "ClaimDraftOutputV2" => (8, 7),
        "CitationVerificationOutputV2" => (10, 9),
        _ => (1, 0),
    }
}
fn typed_final_output(
    value: &Value,
    evidence: &[gurine_agent_orchestration::runtime::EvidenceRecord],
) -> Result<AgentFinalOutput, Failure> {
    let status = match value
        .get("status")
        .or_else(|| value.get("outcome"))
        .and_then(Value::as_str)
    {
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
        citations: typed_citations(value, evidence)?,
    })
}
fn typed_citations(
    value: &Value,
    evidence: &[gurine_agent_orchestration::runtime::EvidenceRecord],
) -> Result<Vec<gurine_agent_orchestration::runtime::Citation>, Failure> {
    value
        .get("citations")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|item| {
            let source_use_id = item
                .get("source_use_id")
                .or_else(|| item.get("sourceUseId"))
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .or_else(|| {
                    item.get("sourceUseSha256")
                        .or_else(|| item.get("source_use_sha256"))
                        .and_then(Value::as_str)
                        .and_then(|sha| evidence.iter().find(|row| row.source_use_sha256 == sha))
                        .map(|row| row.source_use_id)
                })
                .ok_or_else(|| {
                    Failure::Terminal("AGENT_RUNTIME_INVALID", "citation sourceUseSha256".into())
                })?;
            let selected_content_sha256 = item
                .get("selected_content_sha256")
                .or_else(|| item.get("selectedContentSha256"))
                .and_then(Value::as_str)
                .filter(|value| is_sha256_text(value))
                .ok_or_else(|| {
                    Failure::Terminal(
                        "AGENT_RUNTIME_INVALID",
                        "citation selectedContentSha256".into(),
                    )
                })?
                .to_owned();
            Ok(gurine_agent_orchestration::runtime::Citation {
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
async fn parse_tool_call(
    state: &State,
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
    // The provider digest is over the exact flat V2 wire request.  The
    // runtime binding is an internal field and must not alter that digest.
    let provider_arguments = arguments.clone();
    let input_snapshot_id = resolve_snapshot_id(state, turn).await?;
    let binding = json!({
        "run_id": turn.run_id,
        "input_snapshot_id": input_snapshot_id,
        "input_snapshot_sha256": turn.input_snapshot_sha256
    });
    if let Some(map) = arguments.as_object_mut() {
        map.insert("binding".to_owned(), binding);
    }
    let request = decode_tool_request(tool_id, arguments)?;
    // The provider receipt binds the exact closed V2 wire request.  Hashing
    // the projected legacy Rust value would silently change field names and
    // omit authority-required fields, so every tool uses RFC8785/JCS bytes of
    // the original payload (without the internal binding member).
    let request_sha256 = sha256(&canonical_bytes(&provider_arguments)?);
    if let Some(expected) = object
        .get("requestSha256")
        .or_else(|| object.get("argumentsSha256"))
        .and_then(Value::as_str)
        && expected != request_sha256
    {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "requestSha256".into(),
        ));
    }
    Ok(gurine_agent_orchestration::runtime::ToolCall {
        call_id: stable_uuid(call_id.as_bytes()),
        request,
        request_sha256,
    })
}

async fn dispatch_tool_call(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    call: gurine_agent_orchestration::runtime::ToolCall,
    receipt: &Value,
    receipt_id: Uuid,
) -> Result<(Value, String), Failure> {
    use gurine_agent_orchestration::runtime::{SnapshotBinding, TypedDispatcher};
    let binding = SnapshotBinding {
        run_id: turn.run_id,
        input_snapshot_id: resolve_snapshot_id(state, turn).await?,
        input_snapshot_sha256: turn.input_snapshot_sha256.clone(),
    };
    let snapshot = analysis_runtime_snapshot::load_tool_snapshot(state, turn, binding).await?;
    let dispatcher = TypedDispatcher::from_snapshot(snapshot);
    // Claim is durable before any tool code runs.  A crash or cancellation
    // therefore leaves a CLAIMED lease that reconciliation can settle instead
    // of an untracked external side effect.
    let tool_call_id = claim_tool_call(state, turn, agent_type, &call).await?;
    let DispatchedTool {
        response_json,
        pending_source_fetch,
        corpus_parent_source_use_ids,
    } = execute_tool(state, turn, agent_type, &call, &dispatcher).await?;
    let (result, transcript_sha256) =
        tool_result_and_transcript(turn, &call, response_json, receipt)?;
    analysis_tool_persistence::persist_tool_call(
        state,
        turn,
        agent_type,
        tool_call_id,
        &call,
        &result,
        &transcript_sha256,
        receipt_id,
        pending_source_fetch.as_ref(),
        corpus_parent_source_use_ids.as_deref(),
    )
    .await?;
    Ok((result, transcript_sha256))
}

fn is_sha256_text(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

async fn claim_tool_call(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    call: &gurine_agent_orchestration::runtime::ToolCall,
) -> Result<Uuid, Failure> {
    let request = serde_json::to_value(&call.request)
        .map_err(|error| Failure::Terminal("AGENT_TOOL_REQUEST_INVALID", error.to_string()))?;
    let request_canonical = canonical_bytes(&request)?;
    let request_sha256 = sha256(&request_canonical);
    let tool_id = call.request.tool_id().wire_name();
    let (request_schema_sha256, response_schema_sha256) =
        analysis_tool_catalog::tool_schema_hashes(tool_id)
            .ok_or_else(|| Failure::Terminal("AGENT_REGISTRY_DRIFT", tool_id.to_owned()))?;
    let call_text = call.call_id.to_string();
    let tool_call_id = Uuid::new_v4();
    let rights_decision_sha256 = if tool_id == "source.fetch" {
        let request_kind = request
            .get("requestKind")
            .and_then(Value::as_str)
            .unwrap_or("FETCH_URL");
        let source_id = if request_kind == "SEARCH_PUBLIC_WEB" {
            "brave-search-web-v1"
        } else {
            "public-research"
        };
        let rights: Option<Value> = sqlx::query_scalar!(
            "SELECT ops.assert_research_fetch_rights_v1($1,$2)",
            source_id,
            request_kind,
        )
        .fetch_one(&state.pool)
        .await
        .map_err(database)?;
        rights
            .and_then(|value| {
                value
                    .get("decisionSha256")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_UNAVAILABLE", source_id.to_owned()))?
    } else {
        sha256(format!("rights-snapshot:{tool_id}:{request_sha256}").as_bytes())
    };
    sqlx::query!(
        "INSERT INTO ops.agent_tool_calls(
           tool_call_id,agent_run_id,provider_turn_id,call_id,input_snapshot_sha256,
           prior_transcript_sha256,tool_id,tool_catalog_version,tool_catalog_sha256,
           request_schema_id,request_schema_version,request_schema_sha256,response_schema_id,
           response_schema_version,response_schema_sha256,timeout_ms,max_results,request_sha256,
           request_redacted,request_canonical,allowlist_decision_sha256,scope_decision_sha256,
           rights_decision_sha256,classification,status,source_use_count,
           source_use_set_sha256,claim_generation,lease_token_sha256,lease_expires_at,
           version,started_at)
         VALUES($1,$2,$3,$4,$5,$6,$7,'13.0.0+agent-multimodal.1',$8,
           $9,'2',$10,$11,'2',$12,8000,50,$13,$14,$15,$16,$17,$18,'INTERNAL',
           'CLAIMED',0,
           '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',1,$19,
           clock_timestamp() + interval '60 seconds',1,clock_timestamp())
         ON CONFLICT(agent_run_id,call_id) DO NOTHING",
        tool_call_id,
        turn.run_id,
        turn.turn_id,
        &call_text,
        &turn.input_snapshot_sha256,
        &turn.prior_transcript_sha256,
        tool_id,
        sha256(b"tool-catalog-v2"),
        format!("{tool_id}.request.v2"),
        request_schema_sha256,
        format!("{tool_id}.response.v2"),
        response_schema_sha256,
        request_sha256,
        request,
        request_canonical,
        sha256(format!("allowlist:{agent_type}").as_bytes()),
        sha256(b"snapshot-scope"),
        rights_decision_sha256,
        sha256(call_text.as_bytes()),
    )
    .execute(&state.pool)
    .await
    .map_err(database)?;
    let existing: Uuid = sqlx::query_scalar!(
        "SELECT tool_call_id FROM ops.agent_tool_calls WHERE agent_run_id=$1 AND call_id=$2",
        turn.run_id,
        &call_text,
    )
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    Ok(existing)
}

/// A tool result is a provenance edge from every source selected by the
/// initial TOOL_QUERY receipt.  The child preserves the exact snapshot/member,
/// locator and rights tuple and adds the provider turn/tool-call binding; no
/// source identity is reconstructed from an editorial evidence row.
async fn insert_tool_result_source_uses(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    tool_call_id: Uuid,
    tool_id: &str,
    result_sha256: &str,
    provider_receipt_id: Option<Uuid>,
    corpus_parent_source_use_ids: Option<&[Uuid]>,
) -> Result<(), Failure> {
    sqlx::query(
        r#"
        WITH parents AS (
          SELECT * FROM ops.agent_source_uses
           WHERE agent_run_id=$1 AND use_kind='TOOL_QUERY'
             AND ($7::uuid[] IS NULL OR source_use_id=ANY($7))
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
            'providerReceiptId',$6,'occurredAt',i.new_occurred_at
          ) AS payload
          FROM identities i
        ), payloads AS (
          SELECT u.*, encode(extensions.digest(ops.canonical_jsonb_v1(u.payload),'sha256'),'hex') AS digest
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
          $6,CASE WHEN $6 IS NULL THEN NULL ELSE (SELECT btrim(provider_receipt_sha256::text) FROM ops.agent_provider_turns WHERE provider_turn_id=$2) END,p.new_occurred_at,
          ops.canonical_jsonb_v1(p.payload || jsonb_build_object('sourceUseSha256',p.digest)),p.digest
        FROM payloads p
        ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
        "#,
    )
    .bind(turn.run_id)
    .bind(turn.turn_id)
    .bind(tool_call_id)
    .bind(tool_id)
    .bind(result_sha256)
    .bind(provider_receipt_id)
    .bind(corpus_parent_source_use_ids.map(<[Uuid]>::to_vec))
    .execute(&mut *executor)
    .await
    .map_err(database)?;
    Ok(())
}

async fn resolve_snapshot_id(state: &State, turn: &ProviderTurnIdentity) -> Result<Uuid, Failure> {
    if let Some(snapshot_id) = turn.dataset_snapshot_id {
        return sqlx::query_scalar!(
            "SELECT ds.id FROM ops.agent_runs r
              JOIN core.dataset_snapshots ds
                ON ds.id=r.dataset_snapshot_id
               AND ds.snapshot_sha256=r.input_snapshot_hash
             WHERE r.id=$1 AND r.run_contract_version=2
               AND ds.id=$2 AND ds.snapshot_sha256=CAST($3 AS char(64))
               AND ds.snapshot_kind='AGENT_CASE' AND ds.state='READY'",
            turn.run_id,
            snapshot_id,
            &turn.input_snapshot_sha256,
        )
        .fetch_optional(&state.pool)
        .await
        .map_err(database)?
        .ok_or_else(|| {
            Failure::Terminal(
                "AGENT_EVIDENCE_SCOPE_INVALID",
                "v2 snapshot identity".to_owned(),
            )
        });
    }
    // Legacy v1 runs predate the physical dataset_snapshot_id binding. Keep
    // their digest lookup for compatibility; every new automatic run is v2
    // and must take the exact branch above.
    sqlx::query_scalar!(
        "SELECT id FROM core.dataset_snapshots
          WHERE snapshot_sha256=CAST($1 AS char(64)) AND snapshot_kind='AGENT_CASE' AND state='READY'
          ORDER BY ready_at DESC NULLS LAST, id LIMIT 1",
        &turn.input_snapshot_sha256,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "snapshot identity".into()))
}

async fn resolve_snapshot_id_for_dispatch(
    state: &State,
    turn: &ProviderTurnIdentity,
) -> Result<Uuid, Failure> {
    resolve_snapshot_id(state, turn).await
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
        let request_sha256 =
            provider_request_sha256(request).map_err(|_| ProviderRuntimeError::InvalidReceipt)?;
        let mut receipt = ProviderReceipt {
            idempotency_key: request.idempotency_key.clone(),
            request_sha256,
            outcome: ProviderOutcome::FinalAccepted,
            cost_micros_krw: self.cost_micros,
            receipt_sha256: String::new(),
        };
        receipt.receipt_sha256 =
            provider_receipt_sha256(&receipt).map_err(|_| ProviderRuntimeError::InvalidReceipt)?;
        Ok(ProviderReply {
            envelope: ProviderEnvelope::FinalOutput(self.output.clone()),
            receipt,
        })
    }
}
