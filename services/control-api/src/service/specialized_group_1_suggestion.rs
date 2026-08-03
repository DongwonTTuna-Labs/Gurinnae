use super::*;

struct SuggestionContext {
    id: Uuid,
    expected_version: i64,
    stored_payload_sha256: String,
    suggestion_type: String,
    case_id: Uuid,
    payload: Value,
    input_snapshot_sha256: String,
}

struct SuggestionInput {
    id: Uuid,
    expected_version: i64,
    payload_sha256: Option<String>,
    reason: String,
}

impl SuggestionInput {
    fn parse(payload: &Map<String, Value>) -> Result<Self, ServiceError> {
        Ok(Self {
            id: uuid_value(payload, &["suggestionId"]).ok_or(ServiceError::InvalidRequest)?,
            expected_version: payload
                .get("expectedVersion")
                .and_then(Value::as_i64)
                .ok_or(ServiceError::InvalidRequest)?,
            // The v13 authority contract does not expose the persisted
            // payload digest as a request field.  When a trusted caller
            // supplies the optional digest we still bind it; otherwise the
            // version-guarded row digest remains the canonical value.
            payload_sha256: string_value(payload, "payloadSha256")
                .filter(|value| is_sha256(value))
                .map(ToOwned::to_owned),
            reason: string_value(payload, "reason")
                .ok_or(ServiceError::InvalidRequest)?
                .to_owned(),
        })
    }
}

pub(crate) async fn arm_acceptagentsuggestion_rejectagentsuggestion(
    operation: &str,
    payload: &Map<String, Value>,
    request_id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let input = SuggestionInput::parse(payload)?;
    let context = load_context(&input, tx).await?;
    let decision = if operation == "acceptAgentSuggestion" {
        "ACCEPT"
    } else {
        "REJECT"
    };
    let audit = append_audit(request_id, actor, session_id, &input, decision, tx).await?;
    if decision == "ACCEPT" {
        materialize_accept(&context, &input.reason, actor, audit, field_keys, tx).await?;
    } else {
        reject_suggestion(&context, &input.reason, actor, audit, tx).await?;
    }
    Ok(())
}

async fn load_context(
    input: &SuggestionInput,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<SuggestionContext, ServiceError> {
    let row = sqlx::query(
        "SELECT case_id,suggestion_type,payload,payload_sha256,input_snapshot_sha256,version \
           FROM ops.agent_suggestions WHERE id=$1 AND status='PENDING' FOR UPDATE",
    )
    .bind(input.id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::VersionConflict)?;
    let payload: Value = row.try_get("payload").map_err(db)?;
    let stored_payload_sha256: String = row
        .try_get::<Option<String>, _>("payload_sha256")
        .map_err(db)?
        .unwrap_or_else(|| {
            serde_json::to_vec(&payload)
                .map(|canonical| sha256(&canonical))
                .unwrap_or_else(|_| sha256(b"null"))
        });
    let input_snapshot_sha256: String = row
        .try_get::<Option<String>, _>("input_snapshot_sha256")
        .map_err(db)?
        .unwrap_or_else(|| stored_payload_sha256.clone());
    let context = SuggestionContext {
        id: input.id,
        expected_version: input.expected_version,
        stored_payload_sha256,
        suggestion_type: row.try_get("suggestion_type").map_err(db)?,
        case_id: row.try_get("case_id").map_err(db)?,
        payload,
        input_snapshot_sha256,
    };
    let version: i64 = row.try_get("version").map_err(db)?;
    if version != input.expected_version
        || input
            .payload_sha256
            .as_deref()
            .is_some_and(|digest| digest != context.stored_payload_sha256)
    {
        return Err(ServiceError::VersionConflict);
    }
    Ok(context)
}

async fn append_audit(
    request_id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    input: &SuggestionInput,
    decision: &str,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Uuid, ServiceError> {
    sqlx::query_scalar::<_, Uuid>(
        "SELECT ops.append_audit_event($1,'USER',$2,$3,$4,'AgentSuggestion',$5,'agents.review','SUCCESS',$6,$7,$8)",
    )
    .bind(format!("control:agent-suggestion:{}", input.id))
    .bind(actor.to_string())
    .bind(session_id)
    .bind(if decision == "ACCEPT" { "AGENT_SUGGESTION_ACCEPTED" } else { "AGENT_SUGGESTION_REJECTED" })
    .bind(input.id.to_string())
    .bind(&input.reason)
    .bind(request_id)
    .bind(json!({"suggestionId":input.id,"version":input.expected_version,"payloadSha256":input.payload_sha256,"decision":decision,"reason":input.reason}))
    .fetch_one(&mut **tx)
    .await
    .map_err(db)
}

async fn materialize_accept(
    context: &SuggestionContext,
    reason: &str,
    actor: Uuid,
    audit: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let action_kind = match context.suggestion_type.as_str() {
        "HYPOTHESIS" | "CLAIM" | "TASK" | "COMPARABLE" | "COMMUNICATION" => {
            context.suggestion_type.as_str()
        }
        _ => return Err(ServiceError::InvalidRequest),
    };
    let object_scope_digest = sha256(context.case_id.to_string().as_bytes());
    let target_type = match action_kind {
        "COMMUNICATION" => "COMMUNICATION_INTENT",
        "TASK" => "TASK",
        _ => "CASE",
    };
    // The action-approval tables are intentionally write-protected from the
    // Control API role.  Use the migration-owned SECURITY DEFINER boundary so
    // the proposal, version, audit, and outbox rows are created atomically.
    let action_request = json!({
        "actionKind": action_kind,
        "origin": {
            "kind": "AGENT_PROPOSAL",
            "id": context.id,
            "version": context.expected_version,
            "digest": context.stored_payload_sha256,
        },
        "rationale": reason,
        "draft": {
            "kind": action_kind,
            "target": {
                "type": target_type,
                "id": context.case_id,
                "version": 1,
                "digest": context.input_snapshot_sha256,
            },
            "objectScopeDigest": object_scope_digest,
            "contentDigest": context.stored_payload_sha256,
            "proposal": context.payload,
        },
    });
    let action_request = seal_action_request("createActionProposal", action_request, field_keys)?;
    let action_receipt: Value =
        sqlx::query_scalar("SELECT ops.execute_action_approval_v1('createActionProposal',$1,$2)")
            .bind(action_request)
            .bind(actor)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
    let action_id = action_receipt
        .get("proposalId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::Persistence)?;
    let receipt_digest = action_receipt
        .get("receiptDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let content_digest = action_receipt
        .get("contentDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    sqlx::query(
        "UPDATE ops.agent_suggestions SET status='ACCEPTED',decision_reason=$2,decided_by=$3,decided_at=clock_timestamp(),version=version+1,decision_kind='ACCEPT',decision_sha256=CAST($4 AS char(64)),decision_audit_event_id=$5,materialized_target_type='ACTION_PROPOSAL_DRAFT',materialized_target_id=$6,materialized_target_version=1,materialized_target_digest=CAST($7 AS char(64)),materialized_action_proposal_id=$6,materialization_receipt_sha256=CAST($8 AS char(64)) WHERE id=$1 AND version=$9",
    )
    .bind(context.id).bind(reason).bind(actor)
    .bind(sha256(format!("ACCEPT:{}:{}:{}", context.id, context.expected_version, reason).as_bytes()))
    .bind(audit).bind(action_id).bind(content_digest).bind(&receipt_digest)
    .bind(context.expected_version).execute(&mut **tx).await.map_err(db)?;
    Ok(())
}

#[expect(
    dead_code,
    reason = "legacy action proposal writer retained for migration compatibility"
)]
#[expect(
    clippy::too_many_arguments,
    reason = "legacy writer binds the complete immutable proposal row"
)]
async fn insert_action_proposal(
    action_id: Uuid,
    action_kind: &str,
    context: &SuggestionContext,
    target_type: &str,
    object_scope_digest: &str,
    receipt_digest: &str,
    actor: Uuid,
    audit: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    sqlx::query(
        "INSERT INTO ops.action_proposals(id,action_kind,origin_kind,origin_id,origin_version,origin_digest,target_type,target_id,target_version,target_digest,object_scope_digest,created_by,owner_user_id,last_receipt_digest,last_audit_event_id) VALUES($1,$2,'AGENT_PROPOSAL',$3,$4,CAST($5 AS char(64)),$6,$7,1,CAST($8 AS char(64)),CAST($9 AS char(64)),$10,$10,CAST($11 AS char(64)),$12)",
    )
    .bind(action_id).bind(action_kind).bind(context.id).bind(context.expected_version)
    .bind(&context.stored_payload_sha256).bind(target_type).bind(context.case_id.to_string())
    .bind(&context.input_snapshot_sha256).bind(object_scope_digest).bind(actor).bind(receipt_digest)
    .bind(audit).execute(&mut **tx).await.map_err(db)?;
    Ok(())
}

#[expect(
    dead_code,
    reason = "legacy action version writer retained for migration compatibility"
)]
async fn insert_action_version(
    action_id: Uuid,
    action_kind: &str,
    context: &SuggestionContext,
    reason: &str,
    actor: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let canonical = serde_json::to_vec(&context.payload).map_err(|_| ServiceError::Persistence)?;
    let rationale = serde_json::to_vec(
        &json!({"reason":reason,"inputSnapshotSha256":context.input_snapshot_sha256}),
    )
    .map_err(|_| ServiceError::Persistence)?;
    let encrypted_payload = encrypt_control_field(
        field_keys,
        "ops.action_proposal_versions",
        "payload_encrypted",
        action_id,
        "json",
        &canonical,
    )?;
    let encrypted_rationale = encrypt_control_field(
        field_keys,
        "ops.action_proposal_versions",
        "rationale_encrypted",
        action_id,
        "json",
        &rationale,
    )?;
    let detail = json!({"actionDetailKind":action_kind,"actionDetail":context.payload});
    let detail_canonical = serde_json::to_vec(&detail).map_err(|_| ServiceError::Persistence)?;
    sqlx::query(
        "INSERT INTO ops.action_proposal_versions(proposal_id,version,state,payload_encrypted,content_digest,rationale_encrypted,rationale_digest,last_editor_id,expires_at,action_detail_kind,action_detail,action_detail_canonical,action_detail_digest) VALUES($1,1,'DRAFT',$2,CAST($3 AS char(64)),$4,CAST($5 AS char(64)),$6,clock_timestamp()+interval '7 days',$7,$8,$9,CAST($10 AS char(64)))",
    )
    .bind(action_id).bind(encrypted_payload).bind(&context.stored_payload_sha256).bind(encrypted_rationale)
    .bind(sha256(&rationale)).bind(actor).bind(action_kind).bind(&context.payload).bind(&detail_canonical)
    .bind(sha256(&detail_canonical)).execute(&mut **tx).await.map_err(db)?;
    Ok(())
}

async fn reject_suggestion(
    context: &SuggestionContext,
    reason: &str,
    actor: Uuid,
    audit: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    sqlx::query("UPDATE ops.agent_suggestions SET status='REJECTED',decision_reason=$2,decided_by=$3,decided_at=clock_timestamp(),version=version+1,decision_kind='REJECT',decision_sha256=CAST($4 AS char(64)),decision_audit_event_id=$5 WHERE id=$1 AND version=$6")
        .bind(context.id).bind(reason).bind(actor)
        .bind(sha256(format!("REJECT:{}:{}:{}", context.id, context.expected_version, reason).as_bytes()))
        .bind(audit).bind(context.expected_version).execute(&mut **tx).await.map_err(db)?;
    Ok(())
}
