use super::*;

pub(super) async fn query_agent_run(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "agentRunId")?;
    let mut row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',r.id,'caseId',r.case_id,'agentType',r.agent_type, \
         'objective',r.objective,'evidenceScopeIds',r.evidence_scope_ids,'providerPolicy',r.provider_policy, \
         'provider',r.provider,'model',r.model,'status',r.status,'inputSnapshotHash',r.input_snapshot_hash, \
         'inputEvidence',jsonb_build_object('evidenceIds',r.evidence_scope_ids,'snapshotHash',r.input_snapshot_hash), \
         'promptPolicy',jsonb_build_object(\
             'promptVersions',COALESCE((SELECT jsonb_agg(DISTINCT t.prompt_version ORDER BY t.prompt_version) FROM ops.agent_provider_turns t WHERE t.agent_run_id=r.id),'[]'::jsonb),\
             'routingPolicyVersions',COALESCE((SELECT jsonb_agg(DISTINCT t.routing_policy_version ORDER BY t.routing_policy_version) FROM ops.agent_provider_turns t WHERE t.agent_run_id=r.id),'[]'::jsonb),\
             'outputSchemas',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',x.output_schema_id,'version',x.output_schema_version,'sha256',x.output_schema_sha256) ORDER BY x.output_schema_id,x.output_schema_version) FROM (SELECT DISTINCT t.output_schema_id,t.output_schema_version,t.output_schema_sha256 FROM ops.agent_provider_turns t WHERE t.agent_run_id=r.id) x),'[]'::jsonb)),\
         'providerTurns',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',t.provider_turn_id,'provider',t.provider_candidate_id,'model',t.model_id,'providerMode',t.provider_mode,'status',t.status,'promptVersion',t.prompt_version,'promptSha256',t.prompt_sha256,'outputSchemaVersion',t.output_schema_version,'outputSchemaSha256',t.output_schema_sha256,'routingPolicyVersion',t.routing_policy_version,'providerTurnSha256',t.provider_turn_sha256,'inputSnapshotHash',t.input_snapshot_sha256,'providerReceiptId',t.provider_receipt_id,'providerReceiptSha256',t.provider_receipt_sha256,'requestSha256',t.request_sha256,'outputSha256',t.envelope_payload_sha256,'completedAt',t.completed_at) ORDER BY t.turn_sequence,t.attempt_sequence) FROM ops.agent_provider_turns t WHERE t.agent_run_id=r.id),'[]'::jsonb),\
         'output',r.output_payload,'validation',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',v.validation_id,'providerTurnId',v.provider_turn_id,'status',v.validation_status,'schemaStatus',v.schema_status,'citationStatus',v.citation_status,'policyStatus',v.policy_status,'outputStatus',v.output_status,'failureCode',v.failure_code,'failureDetails',v.failure_details_redacted,'validatedOutcome',v.validated_outcome,'validatedOutcomeSha256',v.validated_outcome_sha256,'citationCount',v.citation_count,'proposalCount',v.proposal_count,'validatorVersion',v.validator_version,'validationPolicyVersion',v.validation_policy_version,'validatedAt',v.validated_at) ORDER BY v.validated_at) FROM ops.agent_output_validations v WHERE v.agent_run_id=r.id),'[]'::jsonb),\
         'sourceUses',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',u.source_use_id,'kind',u.use_kind,'sourceKind',u.source_kind,'sourceDocumentId',u.source_document_id,'sourceAssetId',u.source_asset_id,'sourceAssetRevision',u.source_asset_revision,'sourceContentSha256',u.source_content_sha256,'evidenceSegmentId',u.evidence_segment_id,'researchArtifactId',u.research_artifact_id,'locatorKind',u.locator_kind,'locatorValue',u.locator_value,'selectedContentSha256',u.selected_content_sha256,'classification',u.classification,'accessRight',u.access_right,'rightsBindingKind',u.rights_binding_kind,'rightsPolicyVersion',u.rights_policy_version,'sourceUseSha256',u.source_use_sha256,'occurredAt',u.occurred_at) ORDER BY u.occurred_at) FROM ops.agent_source_uses u WHERE u.agent_run_id=r.id),'[]'::jsonb),\
         'citations',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',c.citation_id,'proposalId',c.proposal_id,'validationId',c.validation_id,'sourceKind',c.source_kind,'sourceUseId',c.source_use_id,'sourceId',c.source_id,'locatorKind',c.locator_kind,'locatorValue',c.locator_value,'contentSha256',c.content_sha256,'supports',c.supports_redacted,'citationDigest',c.citation_digest) ORDER BY c.proposal_id,c.citation_ordinal) FROM ops.agent_proposal_citations c WHERE c.agent_run_id=r.id),'[]'::jsonb),\
         'suggestions',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',s.id,'caseId',s.case_id,'type',s.suggestion_type,'payload',s.payload,'evidenceIds',s.evidence_ids,'citationChecks',s.citation_checks,'status',s.status,'decisionReason',s.decision_reason,'decidedBy',s.decided_by,'decidedAt',s.decided_at,'version',s.version) ORDER BY s.created_at) FROM ops.agent_suggestions s WHERE s.agent_run_id=r.id),'[]'::jsonb),\
         'safetyFlags',COALESCE((SELECT jsonb_agg(DISTINCT v.failure_code ORDER BY v.failure_code) FROM ops.agent_output_validations v WHERE v.agent_run_id=r.id AND v.failure_code IS NOT NULL),'[]'::jsonb),\
         'humanActions',COALESCE((SELECT jsonb_agg(jsonb_build_object('suggestionId',s.id,'decision',s.status,'reason',s.decision_reason,'actorId',s.decided_by,'occurredAt',s.decided_at) ORDER BY s.decided_at) FROM ops.agent_suggestions s WHERE s.agent_run_id=r.id AND s.status IN ('ACCEPTED','REJECTED')),'[]'::jsonb),\
         'budgetLedger',COALESCE(ops.read_agent_run_budget_projection_v1(r.id),'{}'::jsonb),\
         'maxCost',r.max_cost::text,'actualCost',r.actual_cost::text, \
         'startedAt',r.started_at,'completedAt',r.completed_at,'createdAt',r.created_at,'updatedAt',r.updated_at,'version',r.version) \
         FROM ops.agent_runs r WHERE r.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    attach_cas011(&mut row)?;
    Ok(envelope(id, value_status(&row), row))
}

pub(super) async fn list_case_agent_runs(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let items: Value = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'agentType',r.agent_type,'objective',r.objective,'status',r.status,'maxCost',r.max_cost::text,'actualCost',r.actual_cost::text,'version',r.version,'createdAt',r.created_at,'inputSnapshotHash',r.input_snapshot_hash,'validation',COALESCE((SELECT jsonb_agg(jsonb_build_object('status',v.validation_status,'schemaStatus',v.schema_status,'citationStatus',v.citation_status,'policyStatus',v.policy_status,'failureCode',v.failure_code,'validatedAt',v.validated_at) ORDER BY v.validated_at DESC) FROM ops.agent_output_validations v WHERE v.agent_run_id=r.id),'[]'::jsonb),'suggestionCounts',jsonb_build_object('pending',COALESCE((SELECT count(*) FROM ops.agent_suggestions s WHERE s.agent_run_id=r.id AND s.status='PENDING'),0),'accepted',COALESCE((SELECT count(*) FROM ops.agent_suggestions s WHERE s.agent_run_id=r.id AND s.status='ACCEPTED'),0),'rejected',COALESCE((SELECT count(*) FROM ops.agent_suggestions s WHERE s.agent_run_id=r.id AND s.status='REJECTED'),0)),'sourceUseCount',COALESCE((SELECT count(*) FROM ops.agent_source_uses u WHERE u.agent_run_id=r.id),0),'budgetLedger',COALESCE(ops.read_agent_run_budget_projection_v1(r.id),'{}'::jsonb)) ORDER BY r.created_at DESC),'[]'::jsonb) FROM ops.agent_runs r WHERE r.case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?;
    let mut response = json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?});
    response["analysisVm"] = cas010_projection(case_id, &items)?;
    Ok(response)
}

pub(super) async fn list_action_approval_queue(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar("SELECT ops.read_action_queue_v1()")
        .fetch_one(pool)
        .await
        .map_err(db)?;
    let items = normalize_action_queue_items(items);
    let (items, next_cursor) = filter_action_queue_items(items, parameters)?;
    action_queue_page(items, next_cursor, parameters)
}

pub(super) async fn get_action_proposal(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = parameters
        .get("proposalId")
        .or_else(|| parameters.get("id"))
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    let value = sqlx::query_scalar::<_, Option<Value>>("SELECT ops.read_action_proposal_v1($1)")
        .bind(id)
        .fetch_one(pool)
        .await
        .map_err(db)?;
    let Some(value) = value else {
        return Err(ServiceError::NotFound);
    };
    Ok(value)
}

pub(super) async fn get_action_execution_receipt(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = parameters
        .get("executionId")
        .or_else(|| parameters.get("id"))
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    let value = sqlx::query_scalar::<_, Option<Value>>("SELECT ops.read_execution_receipt_v1($1)")
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(db)?
        .flatten();
    let Some(value) = value else {
        return Err(ServiceError::NotFound);
    };
    Ok(value)
}

fn action_queue_page(
    items: Value,
    next_cursor: Option<String>,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    let total_approximate = items.as_array().map_or(0, Vec::len);
    Ok(
        json!({"items":items,"appliedFilters":action_queue_filters(parameters),"asOf":format_time(OffsetDateTime::now_utc())?,"nextCursor":next_cursor,"totalApproximate":total_approximate,"operationId":"listActionApprovalQueue","links":[]}),
    )
}

fn action_queue_filters(parameters: &BTreeMap<String, String>) -> Value {
    let values = |name: &str| {
        parameters
            .get(name)
            .map(|value| {
                value
                    .split(',')
                    .filter(|item| !item.is_empty())
                    .map(Value::from)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };
    json!({
        "actionKind": values("actionKind"),
        "proposalState": values("proposalState"),
        "assignmentState": values("assignmentState"),
        "dueBefore": parameters.get("dueBefore"),
        "sort": parameters.get("sort").map(String::as_str).unwrap_or("UPDATED_DESC")
    })
}

fn filter_action_queue_items(
    value: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<(Value, Option<String>), ServiceError> {
    let mut rows = value.as_array().cloned().unwrap_or_default();
    let matches_any = |parameter: &str, actual: Option<&str>| {
        parameters.get(parameter).is_none_or(|expected| {
            expected
                .split(',')
                .filter(|item| !item.is_empty())
                .any(|item| Some(item) == actual)
        })
    };
    rows.retain(|row| {
        let proposal = row.get("proposal");
        let action_kind = proposal
            .and_then(|item| item.get("actionKind"))
            .and_then(Value::as_str);
        let proposal_state = proposal
            .and_then(|item| item.get("state"))
            .and_then(Value::as_str);
        let assignment_state = row
            .get("assignment")
            .and_then(|item| item.get("state"))
            .and_then(Value::as_str);
        let due_before = parameters.get("dueBefore");
        let due_at = row.get("dueAt").and_then(Value::as_str);
        let due_matches = match (due_before, due_at) {
            (None, _) => true,
            (Some(limit), Some(actual)) => {
                let format = time::format_description::well_known::Rfc3339;
                match (
                    time::OffsetDateTime::parse(limit, &format),
                    time::OffsetDateTime::parse(actual, &format),
                ) {
                    (Ok(limit), Ok(actual)) => actual <= limit,
                    _ => false,
                }
            }
            _ => false,
        };
        matches_any("actionKind", action_kind)
            && matches_any("proposalState", proposal_state)
            && matches_any("assignmentState", assignment_state)
            && due_matches
    });
    sort_action_queue_items(&mut rows, parameters);
    let cursor_digest =
        canonical_json_digest(&json!({"rows":rows,"filters":action_queue_filters(parameters)}))?;
    let (offset, limit) = action_queue_window(parameters, &cursor_digest, rows.len())?;
    let next = (offset.saturating_add(limit) < rows.len())
        .then(|| format!("{}:{}", offset + limit, cursor_digest));
    let paged = rows
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect::<Vec<_>>();
    Ok((Value::Array(paged), next))
}

fn sort_action_queue_items(rows: &mut [Value], parameters: &BTreeMap<String, String>) {
    if parameters.get("sort").is_some_and(|sort| sort == "DUE_ASC") {
        rows.sort_by_key(|row| {
            row.get("dueAt")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned()
        });
    } else {
        rows.sort_by_key(|row| {
            std::cmp::Reverse(
                row.get("proposal")
                    .and_then(|item| item.get("updatedAt"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
            )
        });
    }
}

fn action_queue_window(
    parameters: &BTreeMap<String, String>,
    cursor_digest: &str,
    row_count: usize,
) -> Result<(usize, usize), ServiceError> {
    let offset = match parameters.get("cursor") {
        None => 0,
        Some(cursor) => {
            let (raw_offset, digest) =
                cursor.split_once(':').ok_or(ServiceError::InvalidRequest)?;
            if digest != cursor_digest {
                return Err(ServiceError::InvalidRequest);
            }
            raw_offset
                .parse::<usize>()
                .map_err(|_| ServiceError::InvalidRequest)?
        }
    };
    let limit = parameters
        .get("limit")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(row_count);
    Ok((offset, limit))
}

fn normalize_action_queue_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else {
        return json!([]);
    };
    Value::Array(rows.iter().map(normalize_action_queue_item).collect())
}

fn normalize_action_queue_item(row: &Value) -> Value {
    let id = row.get("proposalId").cloned().unwrap_or(Value::Null);
    let digest = |key: &str| normalized_digest(row, key);
    json!({
        "proposal": {
            "proposalId": id,
            "version": row.get("version").cloned().unwrap_or_else(|| json!(1)),
            "actionKind": row.get("actionKind").cloned().unwrap_or_else(|| json!("TASK")),
            "state": row.get("state").cloned().unwrap_or_else(|| json!("DRAFT")),
            "contentDigest": digest("contentDigest"),
            "approvalDigest": digest("approvalDigest"),
            "target": {"targetType": row.get("targetType").cloned().unwrap_or_else(|| json!("CASE")), "targetId": row.get("targetId").cloned().unwrap_or(Value::Null), "expectedVersion": row.get("targetVersion").cloned().unwrap_or_else(|| json!(1))},
            "creator": {"actorType": "HUMAN", "actorId": row.get("createdBy").cloned().unwrap_or(Value::Null), "displayName": "검토 담당자"},
            "lastEditor": {"actorType": "HUMAN", "actorId": row.get("createdBy").cloned().unwrap_or(Value::Null), "displayName": "검토 담당자"},
            "createdAt": row.get("createdAt").cloned().unwrap_or(Value::Null),
            "updatedAt": row.get("updatedAt").cloned().unwrap_or(Value::Null),
            "expiresAt": row.get("expiresAt").cloned().unwrap_or(Value::Null)
        },
        "assignment": normalize_action_assignment(row),
        "quorum": {
            "planDigest": digest("quorumPlanDigest"),
            "requiredSlots": row.get("requiredSlots").cloned().unwrap_or_else(|| json!([])),
            "satisfiedSlots": row.get("satisfiedSlots").cloned().unwrap_or_else(|| json!([])),
            "blockingSlots": row.get("blockingSlots").cloned().unwrap_or_else(|| json!([])),
            "conflictSnapshotDigest": digest("conflictSnapshotDigest"),
            "complete": row.get("blockingSlots").and_then(Value::as_array).is_some_and(|slots| slots.is_empty())
        },
        "dueAt": row.get("dueAt").cloned().or_else(|| row.get("expiresAt").cloned()).unwrap_or(Value::Null),
        "riskClass": normalized_risk_class(row),
        "href": format!("/internal/action-proposals/{}", id.as_str().unwrap_or("unknown"))
    })
}

fn normalized_digest(row: &Value, key: &str) -> Value {
    row.get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .map(Value::from)
        .unwrap_or_else(|| {
            json!("0000000000000000000000000000000000000000000000000000000000000000")
        })
}

fn normalize_action_assignment(row: &Value) -> Value {
    let Some(raw) = row.get("assignment").and_then(Value::as_object) else {
        return Value::Null;
    };
    let approval_digest = raw
        .get("approvalDigest")
        .or_else(|| row.get("approvalDigest"))
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .map(Value::from)
        .unwrap_or_else(|| normalized_digest(row, "approvalDigest"));
    let reviewer = raw
        .get("reviewer")
        .cloned()
        .or_else(|| raw.get("reviewerId").map(|actor_id| json!({"actorType":"HUMAN","actorId":actor_id,"displayName":"Assigned reviewer"})))
        .unwrap_or(Value::Null);
    json!({
        "assignmentId": raw.get("assignmentId").cloned().unwrap_or(Value::Null),
        "version": raw.get("version").or_else(|| raw.get("assignmentVersion")).cloned().unwrap_or_else(|| json!(1)),
        "assignmentGeneration": raw.get("assignmentGeneration").cloned().unwrap_or_else(|| json!(1)),
        "slotKind": raw.get("slotKind").cloned().unwrap_or_else(|| json!("primary")),
        "requiredCapability": raw.get("requiredCapability").cloned().unwrap_or_else(|| json!("actions.review")),
        "reviewer": reviewer,
        "state": raw.get("state").cloned().unwrap_or_else(|| json!("VACANT")),
        "dueAt": raw.get("dueAt").cloned().unwrap_or(Value::Null),
        "approvalDigest": approval_digest
    })
}

fn normalized_risk_class(row: &Value) -> Value {
    row.get("riskClass")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "LOW" | "MEDIUM" | "HIGH" | "CRITICAL"))
        .map(Value::from)
        .unwrap_or_else(|| json!("MEDIUM"))
}

fn envelope(id: Uuid, status: impl Into<String>, data: Value) -> Value {
    let status = status.into();
    json!({"id":id,"status":status,"data":data,"links":[]})
}

fn value_status(value: &Value) -> String {
    value
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("READY")
        .to_owned()
}

fn query_uuid(parameters: &BTreeMap<String, String>, name: &str) -> Result<Uuid, ServiceError> {
    parameters
        .get(name)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)
}
