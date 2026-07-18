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
    let response = response_for(operation, &data)?;
    Ok(Output {
        status: operation.success_status,
        media_type: "application/json",
        body: response,
        replay: false,
    })
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
        // OPS-004 is the canonical BusinessHealthV1 read.  The legacy budget
        // envelope is intentionally not used here because it cannot prove
        // funnel, paid-MVW, retention, or revenue gates.
        "getBudgetOverview" => business_health_query(parameters, pool).await,
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
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'caseId',case_id,'agentType',agent_type, \
         'objective',objective,'evidenceScopeIds',evidence_scope_ids,'providerPolicy',provider_policy, \
         'provider',provider,'model',model,'status',status,'inputSnapshotHash',input_snapshot_hash, \
         'output',output_payload,'maxCost',max_cost::text,'actualCost',actual_cost::text, \
         'startedAt',started_at,'completedAt',completed_at,'version',version) \
         FROM ops.agent_runs WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
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
    if let Some(value) = addendum_queue_query(operation, pool).await? {
        return Ok(value);
    }
    let id = parameters
        .get(detail_key)
        .or_else(|| parameters.get("id"))
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    let value: Option<Value> = match operation {
        "getActionProposal" => sqlx::query_scalar("SELECT ops.read_action_proposal_v1($1)")
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(db)?,
        "getActionExecutionReceipt" => {
            sqlx::query_scalar("SELECT ops.read_execution_receipt_v1($1)")
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(db)?
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
        "getRetentionRequest" => sqlx::query_scalar("SELECT ops.read_retention_request_v1($1)")
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(db)?,
        _ => None,
    };
    let Some(value) = value else {
        return Err(ServiceError::NotFound);
    };
    Ok(value)
}

async fn addendum_queue_query(
    operation: &str,
    pool: &PgPool,
) -> Result<Option<Value>, ServiceError> {
    let query = match operation {
        "listActionApprovalQueue" => "SELECT ops.read_action_queue_v1()",
        "listResponseAppeals" => "SELECT ops.read_appeal_queue_v1()",
        "listRetentionRequests" => "SELECT ops.read_retention_queue_v1()",
        "listRecordClassSchedules" => "SELECT ops.read_record_class_schedule_queue_v1()",
        _ => return Ok(None),
    };
    let items: Value = sqlx::query_scalar(query)
        .fetch_one(pool)
        .await
        .map_err(db)?;
    Ok(Some(json!({"items":items,"nextCursor":null,"links":[]})))
}

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
