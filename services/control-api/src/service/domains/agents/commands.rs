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

pub(super) async fn arm_acceptagentsuggestion_rejectagentsuggestion(
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
    let row = sqlx::query!(
        "SELECT case_id,suggestion_type,payload,payload_sha256,input_snapshot_sha256,version \
           FROM ops.agent_suggestions WHERE id=$1 AND status='PENDING' FOR UPDATE",
        input.id,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::VersionConflict)?;
    let payload = row.payload;
    let stored_payload_sha256 = row.payload_sha256.unwrap_or_else(|| {
        serde_json::to_vec(&payload)
            .map(|canonical| sha256(&canonical))
            .unwrap_or_else(|_| sha256(b"null"))
    });
    let input_snapshot_sha256 = row
        .input_snapshot_sha256
        .unwrap_or_else(|| stored_payload_sha256.clone());
    let context = SuggestionContext {
        id: input.id,
        expected_version: input.expected_version,
        stored_payload_sha256,
        suggestion_type: row.suggestion_type,
        case_id: row.case_id,
        payload,
        input_snapshot_sha256,
    };
    let version = row.version;
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
    sqlx::query_scalar!(
        "SELECT ops.append_audit_event($1,'USER',$2,$3,$4,'AgentSuggestion',$5,'agents.review','SUCCESS',$6,$7,$8)",
        format!("control:agent-suggestion:{}", input.id),
        actor.to_string(),
        session_id,
        if decision == "ACCEPT" {
            "AGENT_SUGGESTION_ACCEPTED"
        } else {
            "AGENT_SUGGESTION_REJECTED"
        },
        input.id.to_string(),
        &input.reason,
        request_id,
        json!({"suggestionId":input.id,"version":input.expected_version,"payloadSha256":input.payload_sha256,"decision":decision,"reason":input.reason}),
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })
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
    let action_receipt: Value = sqlx::query_scalar!(
        "SELECT ops.execute_action_approval_v1('createActionProposal',$1,$2)",
        action_request,
        actor,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })?;
    let (action_id, receipt_digest, content_digest) = parse_action_receipt(&action_receipt)?;
    sqlx::query!(
        "UPDATE ops.agent_suggestions SET status='ACCEPTED',decision_reason=$2,decided_by=$3,decided_at=clock_timestamp(),version=version+1,decision_kind='ACCEPT',decision_sha256=CAST($4 AS char(64)),decision_audit_event_id=$5,materialized_target_type='ACTION_PROPOSAL_DRAFT',materialized_target_id=$6,materialized_target_version=1,materialized_target_digest=CAST($7 AS char(64)),materialized_action_proposal_id=$6,materialization_receipt_sha256=CAST($8 AS char(64)) WHERE id=$1 AND version=$9",
        context.id,
        reason,
        actor,
        sha256(
            format!(
                "ACCEPT:{}:{}:{}",
                context.id, context.expected_version, reason
            )
            .as_bytes()
        ),
        audit,
        action_id,
        content_digest,
        &receipt_digest,
        context.expected_version,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    Ok(())
}

fn parse_action_receipt(action_receipt: &Value) -> Result<(Uuid, String, String), ServiceError> {
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
    Ok((action_id, receipt_digest, content_digest))
}

async fn reject_suggestion(
    context: &SuggestionContext,
    reason: &str,
    actor: Uuid,
    audit: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    sqlx::query!(
        "UPDATE ops.agent_suggestions SET status='REJECTED',decision_reason=$2,decided_by=$3,decided_at=clock_timestamp(),version=version+1,decision_kind='REJECT',decision_sha256=CAST($4 AS char(64)),decision_audit_event_id=$5 WHERE id=$1 AND version=$6",
        context.id,
        reason,
        actor,
        sha256(
            format!(
                "REJECT:{}:{}:{}",
                context.id, context.expected_version, reason
            )
            .as_bytes()
        ),
        audit,
        context.expected_version,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    Ok(())
}

pub(super) async fn arm_startagentrun(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let evidence = payload
        .get("evidenceScopeIds")
        .cloned()
        .ok_or(ServiceError::InvalidRequest)?;
    let evidence_ids = evidence
        .as_array()
        .ok_or(ServiceError::InvalidRequest)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ServiceError::InvalidRequest)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if evidence_ids.is_empty() {
        return Err(ServiceError::InvalidRequest);
    }
    let evidence_snapshot: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object( \
           'id',e.id,'contentSha256',btrim(e.content_sha256::text), \
           'locator',e.source_locator,'updatedAt',e.updated_at, \
           'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb) \
         ) ORDER BY e.id),'[]'::jsonb) \
         FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id \
         WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) \
           AND e.verification_status='VERIFIED'",
        case_id,
        &evidence_ids,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })?;
    if evidence_snapshot
        .as_array()
        .is_none_or(|rows| rows.len() != evidence_ids.len())
    {
        return Err(ServiceError::InvalidRequest);
    }
    let snapshot_hash = agent_case_snapshot_sha256(&case_id.to_string(), &evidence_snapshot)
        .map_err(|_| ServiceError::Persistence)?;
    sqlx::query!(
        "INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids, \
         provider_policy,status,input_snapshot_hash,max_cost,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,'QUEUED',$7,$8,$9)",
        id,
        case_id,
        string_value(payload, "agentType").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "objective").ok_or(ServiceError::InvalidRequest)?,
        evidence,
        string_value(payload, "providerPolicy").ok_or(ServiceError::InvalidRequest)?,
        snapshot_hash,
        decimal_string(payload, "maxCost")?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "AGENT_RUN",
        "analysis-worker",
        json!({"agentRunId":id}),
        format!("agent-run:{id}"),
    )
    .await?;

    Ok(())
}
