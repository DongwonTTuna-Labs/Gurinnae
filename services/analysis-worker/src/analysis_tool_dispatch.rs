use super::analysis_source_fetch::{PendingSourceFetch, dispatch_source_fetch};
use super::{Failure, ProviderTurnIdentity, State, canonical_bytes, is_sha256_text, sha256};
use serde_json::{Value, json};
use uuid::Uuid;

pub(super) struct DispatchedTool {
    pub response_json: Value,
    pub pending_source_fetch: Option<PendingSourceFetch>,
    pub corpus_parent_source_use_ids: Option<Vec<Uuid>>,
}

pub(super) async fn execute_tool(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    dispatcher: &gurine_agent_orchestration::runtime::TypedDispatcher,
) -> Result<DispatchedTool, Failure> {
    if let gurine_agent_orchestration::runtime::ToolRequest::SourceFetch(request) = &call.request {
        let (response, pending) = dispatch_source_fetch(state, turn, call, request).await?;
        validate_source_fetch_response(request, &response)?;
        return Ok(DispatchedTool {
            response_json: response,
            pending_source_fetch: pending,
            corpus_parent_source_use_ids: None,
        });
    }
    let response = dispatcher
        .dispatch(agent_type, &call.request)
        .map_err(|error| Failure::Terminal("AGENT_TOOL_DENIED", error.to_string()))?;
    let corpus_parent_source_use_ids = response.corpus_source_use_ids();
    if corpus_parent_source_use_ids
        .as_ref()
        .is_some_and(|ids| ids.iter().any(Uuid::is_nil))
    {
        return Err(Failure::Terminal(
            "AGENT_TOOL_RESULT_INVALID",
            "corpus source use identity".to_owned(),
        ));
    }
    Ok(DispatchedTool {
        response_json: serde_json::to_value(&response)
            .map_err(|error| Failure::Terminal("AGENT_TOOL_RESULT_INVALID", error.to_string()))?,
        pending_source_fetch: None,
        corpus_parent_source_use_ids,
    })
}

fn validate_source_fetch_response(
    request: &gurine_agent_orchestration::runtime::SourceFetchRequest,
    response: &Value,
) -> Result<(), Failure> {
    let typed: gurine_agent_orchestration::runtime::SourceFetchResponseV2 =
        serde_json::from_value(response.clone()).map_err(|error| {
            Failure::Terminal("SOURCE_FETCH_RESPONSE_INVALID", error.to_string())
        })?;
    let expected_kind = match request.request_kind {
        gurine_agent_orchestration::runtime::SourceRequestKind::SearchPublicWeb => {
            "SEARCH_PUBLIC_WEB"
        }
        gurine_agent_orchestration::runtime::SourceRequestKind::FetchUrl => "FETCH_URL",
    };
    let invalid_artifact = typed.artifacts.iter().any(|artifact| {
        !is_sha256_text(&artifact.content_sha256)
            || !is_sha256_text(&artifact.artifact_sha256)
            || !is_sha256_text(&artifact.response_headers_sha256)
            || !is_sha256_text(&artifact.content_safety_receipt_sha256)
            || !is_sha256_text(&artifact.source_use_sha256)
            || artifact.content_media_type.contains(';')
    });
    if typed.schema_version != "source.fetch.response.v2"
        || typed.request_kind != expected_kind
        || typed.gateway_decision.decision != "ALLOW"
        || typed.gateway_decision.policy_version != "source-policy-v2"
        || !is_sha256_text(&typed.fetch_receipt_sha256)
        || !is_sha256_text(&typed.gateway_decision.policy_sha256)
        || !is_sha256_text(&typed.gateway_decision.decision_sha256)
        || invalid_artifact
    {
        return Err(Failure::Terminal(
            "SOURCE_FETCH_RESPONSE_INVALID",
            "binding".into(),
        ));
    }
    Ok(())
}

pub(super) fn tool_result_and_transcript(
    turn: &ProviderTurnIdentity,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    response_json: Value,
    receipt: &Value,
) -> Result<(Value, String), Failure> {
    let result_sha256 = sha256(
        &serde_json::to_vec(&response_json)
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
    Ok((
        json!({
            "callId": call.call_id,
            "response": response_json,
            "responseSha256": result_sha256,
        }),
        transcript_sha256,
    ))
}
