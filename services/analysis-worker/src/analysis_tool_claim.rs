use super::{
    Failure, ProviderTurnIdentity, State, analysis_tool_catalog, canonical_bytes, database,
    is_sha256_text, sha256,
};
use serde_json::Value;
use uuid::Uuid;

pub(super) async fn claim_tool_call(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    call: &gurine_agent_orchestration::runtime::ToolCall,
) -> Result<Uuid, Failure> {
    let claim = build_tool_call_claim(state, call).await?;
    insert_tool_call_claim(state, turn, agent_type, &claim).await?;
    existing_tool_call_id(state, turn.run_id, &claim.call_text).await
}

struct ToolCallClaim {
    tool_call_id: Uuid,
    call_text: String,
    tool_id: &'static str,
    request_schema_version: &'static str,
    request_schema_number: &'static str,
    request_schema_sha256: &'static str,
    response_schema_version: &'static str,
    response_schema_number: &'static str,
    response_schema_sha256: &'static str,
    request_sha256: String,
    request: Value,
    request_canonical: Vec<u8>,
    rights_decision_sha256: String,
}

fn tool_catalog_sha256() -> String {
    sha256(include_bytes!("../../../specs/agents/tool-catalog.yaml"))
}

async fn build_tool_call_claim(
    state: &State,
    call: &gurine_agent_orchestration::runtime::ToolCall,
) -> Result<ToolCallClaim, Failure> {
    let (request, request_canonical, request_sha256) = validated_tool_request(call)?;
    let request_schema_version = call.request.schema_version();
    let tool_id = call.request.tool_id().wire_name();
    let (request_schema_sha256, response_schema_sha256) =
        analysis_tool_catalog::tool_schema_hashes(tool_id)
            .ok_or_else(|| Failure::Terminal("AGENT_REGISTRY_DRIFT", tool_id.to_owned()))?;
    let response_schema_version = call.request.response_schema_version();
    let request_schema_number = schema_contract_number(request_schema_version)?;
    let response_schema_number = schema_contract_number(response_schema_version)?;
    let call_text = call.call_id.to_string();
    let tool_call_id = Uuid::new_v4();
    let rights_decision_sha256 =
        claim_rights_decision_sha256(state, tool_id, &request, &request_sha256).await?;
    Ok(ToolCallClaim {
        tool_call_id,
        call_text,
        tool_id,
        request_schema_version,
        request_schema_number,
        request_schema_sha256,
        response_schema_version,
        response_schema_number,
        response_schema_sha256,
        request_sha256,
        request,
        request_canonical,
        rights_decision_sha256,
    })
}

fn validated_tool_request(
    call: &gurine_agent_orchestration::runtime::ToolCall,
) -> Result<(Value, Vec<u8>, String), Failure> {
    let request = call.request_wire.clone();
    request
        .get("schemaVersion")
        .and_then(Value::as_str)
        .filter(|version| *version == call.request.schema_version())
        .ok_or_else(|| {
            Failure::Terminal("AGENT_TOOL_REQUEST_INVALID", "schemaVersion".to_owned())
        })?;
    let request_canonical = canonical_bytes(&request)?;
    let request_sha256 = sha256(&request_canonical);
    if request_sha256 != call.request_sha256 {
        return Err(Failure::Terminal(
            "AGENT_TOOL_REQUEST_INVALID",
            "requestSha256".to_owned(),
        ));
    }
    Ok((request, request_canonical, request_sha256))
}

async fn claim_rights_decision_sha256(
    state: &State,
    tool_id: &str,
    request: &Value,
    request_sha256: &str,
) -> Result<String, Failure> {
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
            .as_ref()
            .and_then(primary_rights_decision_sha256)
            .map(str::to_owned)
            .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_UNAVAILABLE", source_id.to_owned()))?
    } else {
        sha256(format!("rights-snapshot:{tool_id}:{request_sha256}").as_bytes())
    };
    Ok(rights_decision_sha256)
}

fn primary_rights_decision_sha256(rights: &Value) -> Option<&str> {
    rights
        .get("primaryDecision")
        .and_then(Value::as_object)
        .and_then(|primary| primary.get("decisionSha256"))
        .and_then(Value::as_str)
        .filter(|digest| is_sha256_text(digest))
}

async fn insert_tool_call_claim(
    state: &State,
    turn: &ProviderTurnIdentity,
    agent_type: &str,
    claim: &ToolCallClaim,
) -> Result<(), Failure> {
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
           $9,$10,$11,$12,$13,$14,8000,50,$15,$16,$17,$18,$19,$20,'INTERNAL',
           'CLAIMED',0,
           '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',1,$21,
           clock_timestamp() + interval '60 seconds',1,clock_timestamp())
         ON CONFLICT(agent_run_id,call_id) DO NOTHING",
        claim.tool_call_id,
        turn.run_id,
        turn.turn_id,
        &claim.call_text,
        &turn.input_snapshot_sha256,
        &turn.prior_transcript_sha256,
        claim.tool_id,
        tool_catalog_sha256(),
        claim.request_schema_version,
        claim.request_schema_number,
        claim.request_schema_sha256,
        claim.response_schema_version,
        claim.response_schema_number,
        claim.response_schema_sha256,
        claim.request_sha256,
        claim.request,
        claim.request_canonical,
        sha256(format!("allowlist:{agent_type}").as_bytes()),
        sha256(b"snapshot-scope"),
        claim.rights_decision_sha256,
        sha256(claim.call_text.as_bytes()),
    )
    .execute(&state.pool)
    .await
    .map_err(database)?;
    Ok(())
}

async fn existing_tool_call_id(
    state: &State,
    run_id: Uuid,
    call_text: &str,
) -> Result<Uuid, Failure> {
    let existing: Uuid = sqlx::query_scalar!(
        "SELECT tool_call_id FROM ops.agent_tool_calls WHERE agent_run_id=$1 AND call_id=$2",
        run_id,
        call_text,
    )
    .fetch_one(&state.pool)
    .await
    .map_err(database)?;
    Ok(existing)
}

fn schema_contract_number(schema: &str) -> Result<&str, Failure> {
    schema
        .rsplit_once('.')
        .and_then(|(_, version)| version.strip_prefix('v'))
        .filter(|version| !version.is_empty() && version.bytes().all(|byte| byte.is_ascii_digit()))
        .ok_or_else(|| Failure::Terminal("AGENT_TOOL_REQUEST_INVALID", "schemaVersion".to_owned()))
}

#[cfg(test)]
mod tests {
    use super::{primary_rights_decision_sha256, tool_catalog_sha256};
    use serde_json::json;

    const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn tool_catalog_digest_pins_the_exact_thirteen_tool_authority_bytes() {
        assert_eq!(
            tool_catalog_sha256(),
            "e2c740a886f8cbab7756eac4325088723cde9ec9a83b6b560bbfc9faa16990ed"
        );
    }

    #[test]
    fn primary_rights_digest_reads_only_the_nested_authority_shape() {
        let rights = json!({
            "primaryDecision": {
                "decisionId": "a4fb4ee0-48c7-5ced-8679-326736231bb4",
                "decisionVersion": 1,
                "decisionSha256": DIGEST
            }
        });

        assert_eq!(primary_rights_decision_sha256(&rights), Some(DIGEST));
    }

    #[test]
    fn primary_rights_digest_rejects_flat_or_missing_shapes() {
        assert_eq!(
            primary_rights_decision_sha256(&json!({"decisionSha256": DIGEST})),
            None
        );
        assert_eq!(
            primary_rights_decision_sha256(&json!({"primaryDecision": {}})),
            None
        );
    }

    #[test]
    fn primary_rights_digest_rejects_malformed_hashes() {
        assert_eq!(
            primary_rights_decision_sha256(&json!({
                "primaryDecision": {"decisionSha256": "not-a-sha256"}
            })),
            None
        );
        assert_eq!(
            primary_rights_decision_sha256(&json!({
                "primaryDecision": {
                    "decisionSha256":
                        "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
                }
            })),
            None
        );
    }
}
