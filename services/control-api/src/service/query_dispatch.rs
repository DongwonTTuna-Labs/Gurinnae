use super::*;

pub(super) async fn query(
    operation: &OperationSpec,
    request: &HttpRequest,
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Output, ServiceError> {
    let parameters = query_parameters(request);
    let mut data = canonical_query(operation.id, &parameters, claims, pool).await?;
    if let Some(object) = data.as_object_mut() {
        object.entry("operationId").or_insert(json!(operation.id));
    }
    let data = if operation.id == "getActionProposal" {
        action_proposal_detail_response(data)
    } else {
        data
    };
    let response = response_for(operation, &data)?;
    Ok(Output {
        status: operation.success_status,
        media_type: "application/json",
        body: response,
        replay: false,
    })
}
include!("query_action_proposal.rs");

fn normalize_history(mut value: Value, order: &str, as_of: &Value) -> Value {
    let object = value.as_object_mut().cloned().unwrap_or_default();
    let mut normalized = object;
    normalized.entry("items").or_insert_with(|| json!([]));
    normalized.entry("order").or_insert_with(|| json!(order));
    normalized.entry("asOf").or_insert_with(|| as_of.clone());
    normalized.entry("pageDigest").or_insert_with(|| {
        json!("0000000000000000000000000000000000000000000000000000000000000000")
    });
    normalized.entry("nextCursor").or_insert(Value::Null);
    normalized.entry("complete").or_insert(json!(true));
    Value::Object(normalized)
}

pub(super) async fn canonical_query(
    operation: &str,
    parameters: &BTreeMap<String, String>,
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    if gurine_api_contracts::addendum::is_control_operation(operation)
        && gurine_api_contracts::addendum::control_operation(operation)
            .is_some_and(|spec| spec.operation_kind == "QUERY")
    {
        return addendum_query(operation, parameters, pool).await;
    }
    match operation {
        "getCurrentAccount" => query_current_account(claims, pool).await,
        "getAgentRun" => query_agent_run(parameters, pool).await,
        "getAuditExport" => query_audit_export(parameters, pool).await,
        "getCorrectionWorkspace" => query_correction_workspace(parameters, pool).await,
        "getRuleEvaluation" => query_rule_evaluation(parameters, pool).await,
        "getCurrentUserCapabilities" => Ok(json!({
            "id":claims.sub,"status":"ACTIVE","data":{"capabilities":claims.capabilities,
            "rolesVersion":claims.roles_version},"links":[]
        })),

        "getCaseWorkspaceOverview"
        | "getInternalCase"
        | "getResponseRequestComposer"
        | "getReviewReadiness" => case_query(operation, parameters, pool).await,

        "getEvidenceWorkspace" => evidence_query(parameters, pool).await,
        "getInternalDashboard" => dashboard_query(claims, pool).await,
        "getInternalRuleVersion" | "getRuleActivationReadiness" => {
            let id = query_uuid(parameters, "ruleVersionId")?;
            let row: Value = sqlx::query_scalar(
                "SELECT jsonb_build_object('id',id,'ruleId',rule_id,'versionName',version,'name',name, \
                 'description',description,'configuration',configuration,'implementationDigest',code_digest, \
                 'status',status,'effectiveAt',effective_at,'retiredAt',retired_at,'rowVersion',row_version, \
                 'evaluationDigest',activation_evaluation_digest,'rollout',activation_rollout, \
                 'activationReason',activation_reason) FROM core.rule_versions WHERE id=$1",
            )
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?;
            Ok(envelope(id, value_status(&row), row))
        }
        "getInternalSource" => source_query(parameters, pool).await,
        "getJob" => job_query(parameters, pool).await,
        "getOperationsOverview" => operations_query(pool).await,
        "getPublicationPreview" => publication_preview_query(parameters, pool).await,
        "getPublicationReceipt" => publication_receipt_query(parameters, pool).await,
        "getPublishConfirmation" => publish_confirmation_query(parameters, pool).await,
        "getReviewSnapshot" => review_snapshot_query(parameters, pool).await,

        "getSchemaDrift" => schema_drift_query(parameters, pool).await,
        "getSignalTriageView" => signal_query(parameters, pool).await,
        "getSourceRun" => source_run_query(parameters, pool).await,
        "getUserAccessDetail" => user_access_query(parameters, pool).await,
        "estimateBackfill" => estimate_backfill_query(parameters, pool).await,
        // OPS-004 is the v13 authority BudgetOverview read. Supplemental
        // BusinessHealth remains a separate non-authority projection.
        "getBudgetOverview" => budget_overview_query(pool).await,
        "downloadSourceRunReport" => source_run_download(parameters, pool).await,
        "exportCostReport" => cost_export_query(parameters, pool).await,
        "listCaseAuditEvents" | "searchAuditEvents" => audit_query(pool, parameters).await,
        _ if operation.starts_with("list") || operation == "searchInternalRecords" => {
            canonical_list_query(operation, parameters, claims, pool).await
        }
        _ => Err(ServiceError::Persistence),
    }
}

pub(super) async fn query_current_account(
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let user = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let data: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('userId',u.id,'email',u.email,'displayName',u.display_name, \
         'status',u.status,'rolesVersion',$3::bigint,'sessionId',$2::text) \
         FROM ops.users u WHERE u.id=$1",
    )
    .bind(user)
    .bind(&claims.sid)
    .bind(claims.roles_version)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(user, "ACTIVE", data))
}

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

pub(super) async fn query_audit_export(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "auditExportId")?;
    sqlx::query_scalar::<_, Value>(
        "SELECT jsonb_build_object('id',id,'status',status,'format',format,'scope',scope, \
         'from',from_at,'to',to_at,'objectType',object_type,'objectId',object_id, \
         'watermarkPolicy',watermark_policy,'createdAt',created_at,'startedAt',started_at, \
         'completedAt',completed_at,'expiresAt',expires_at,'rowCount',row_count, \
         'contentSha256',content_sha256,'downloadUrl',NULL::text, \
         'failureCode',failure_code,'links','[]'::jsonb) \
         FROM ops.audit_exports WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)
}

pub(super) async fn query_correction_workspace(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "correctionId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'caseId',case_id,'sourceRevision',source_revision, \
         'targetRevision',target_revision,'summary',summary,'reason',reason,'affectedClaimIds', \
         affected_claim_ids,'replacementContent',replacement_content,'status',status, \
         'assignedUserId',assigned_user_id,'resolution',resolution,'version',version) \
         FROM editorial.corrections WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

pub(super) async fn query_rule_evaluation(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "evaluationRunId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'ruleVersionId',rule_version_id, \
         'datasetSnapshotId',dataset_snapshot_id,'evaluationProfile',evaluation_profile, \
         'status',status,'result',result_payload,'resultDigest',result_digest, \
         'reason',reason,'startedAt',started_at,'completedAt',completed_at) \
         FROM core.rule_evaluations WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn addendum_query(
    operation: &str,
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let detail_key = match operation {
        "getActionProposal" => "proposalId",
        "getActionExecutionReceipt" => "executionId",
        "getCommunicationDeliveryReceipt" => "deliveryId",
        "getIncident" => "incidentId",
        "getResponseAppealWorkspace" | "getRetentionRequest" => {
            if operation == "getResponseAppealWorkspace" {
                "appealId"
            } else {
                "retentionRequestId"
            }
        }
        _ => "id",
    };
    if let Some(value) = addendum_queue_query(operation, parameters, pool).await? {
        return Ok(value);
    }
    let id = parameters
        .get(detail_key)
        .or_else(|| parameters.get("id"))
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    let value: Option<Value> = match operation {
        "getActionProposal" => {
            sqlx::query_scalar::<_, Option<Value>>("SELECT ops.read_action_proposal_v1($1)")
                .bind(id)
                .fetch_one(pool)
                .await
                .map_err(db)?
        }
        "getActionExecutionReceipt" => {
            sqlx::query_scalar::<_, Option<Value>>("SELECT ops.read_execution_receipt_v1($1)")
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(db)?
                .flatten()
        }
        "getCommunicationDeliveryReceipt" => {
            sqlx::query_scalar("SELECT ops.read_communication_delivery_receipt_v1($1)")
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(db)?
        }
        "getIncident" => sqlx::query_scalar("SELECT ops.read_incident_v1($1)")
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(db)?,
        "getResponseAppealWorkspace" => {
            sqlx::query_scalar("SELECT ops.read_appeal_workspace_v1($1)")
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(db)?
        }
        "getRetentionRequest" => {
            sqlx::query_scalar::<_, Option<Value>>("SELECT ops.read_retention_request_v1($1)")
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(db)?
                .flatten()
        }
        _ => None,
    };
    let Some(value) = value else {
        return Err(ServiceError::NotFound);
    };
    Ok(value)
}
include!("query_addendum_queue.rs");
pub(super) fn envelope(id: Uuid, status: impl Into<String>, data: Value) -> Value {
    let status = status.into();
    json!({"id":id,"status":status,"data":data,"links":[]})
}

pub(super) fn value_status(value: &Value) -> String {
    value
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("READY")
        .to_owned()
}

pub(super) fn query_uuid(
    parameters: &BTreeMap<String, String>,
    name: &str,
) -> Result<Uuid, ServiceError> {
    parameters
        .get(name)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)
}
