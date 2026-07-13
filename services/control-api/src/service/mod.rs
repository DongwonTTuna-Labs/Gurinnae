use std::{collections::BTreeMap, sync::OnceLock};

use actix_web::HttpRequest;
use gurine_api_contracts::{
    OperationSpec,
    event::{producer_events, project_payload, requires_outbox},
};
use gurine_auth::{
    assertion::actor::ActorClaims,
    envelope::{EnvelopeKeyRing, encrypt},
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, PgPool, Postgres, Row, Transaction};
use thiserror::Error;
use time::{Date, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

const CONTROL_OPENAPI: &str = include_str!("../../../../specs/generated/control-api.openapi.json");
static SPEC: OnceLock<Value> = OnceLock::new();
static CONCURRENCY: OnceLock<ConcurrencyCatalog> = OnceLock::new();
const CONCURRENCY_JSON: &str =
    include_str!("../../../../specs/application/optimistic-concurrency.runtime.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConcurrencyCatalog {
    contracts: Vec<ConcurrencyContract>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConcurrencyContract {
    operation_id: String,
    version_field: String,
    guard_relation: String,
    guard_columns: Vec<String>,
    request_placeholders: Vec<String>,
}

pub struct Output {
    pub status: u16,
    pub media_type: &'static str,
    pub body: Value,
    pub replay: bool,
}

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("control request is invalid")]
    InvalidRequest,
    #[error("control resource was not found")]
    NotFound,
    #[error("control resource version conflicts")]
    VersionConflict,
    #[error("idempotency key was reused with different request bytes")]
    IdempotencyConflict,
    #[error("control persistence is unavailable")]
    Persistence,
}

pub async fn execute(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    claims: &ActorClaims,
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    request_id: Uuid,
) -> Result<Output, ServiceError> {
    if operation.operation_kind == "QUERY" {
        return query(operation, request, claims, pool).await;
    }
    command(
        operation, request, body, claims, pool, field_keys, request_id,
    )
    .await
}

async fn command(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    claims: &ActorClaims,
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    request_id: Uuid,
) -> Result<Output, ServiceError> {
    let payload = if body.is_empty() {
        json!({})
    } else {
        serde_json::from_slice::<Value>(body).map_err(|_| ServiceError::InvalidRequest)?
    };
    let payload_object = payload.as_object().ok_or(ServiceError::InvalidRequest)?;
    validate_command(operation.id, payload_object)?;
    let actor_id = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let session_id = Uuid::parse_str(&claims.sid).map_err(|_| ServiceError::InvalidRequest)?;
    let idempotency_key = request
        .headers()
        .get("idempotency-key")
        .and_then(|value| value.to_str().ok())
        .filter(|value| (8..=200).contains(&value.len()) && value.is_ascii())
        .ok_or(ServiceError::InvalidRequest)?;
    let scope = format!("control:{}:{}", claims.sub, operation.id);
    let key_hash = sha256(idempotency_key.as_bytes());
    let request_hash = sha256(body);
    let mut transaction = pool.begin().await.map_err(db)?;
    let inserted = sqlx::query(
        "INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) VALUES($1,$2,$3,clock_timestamp()+interval '24 hours') ON CONFLICT DO NOTHING",
    )
    .bind(&scope)
    .bind(&key_hash)
    .bind(&request_hash)
    .execute(&mut *transaction)
    .await
    .map_err(db)?
    .rows_affected();
    let idempotency = sqlx::query(
        "SELECT request_hash,response_status,response_body FROM ops.idempotency_keys WHERE scope=$1 AND key_hash=$2 FOR UPDATE",
    )
    .bind(&scope)
    .bind(&key_hash)
    .fetch_one(&mut *transaction)
    .await
    .map_err(db)?;
    if idempotency
        .try_get::<String, _>("request_hash")
        .map_err(db)?
        .trim()
        != request_hash
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    if inserted == 0
        && let (Some(status), Some(response)) = (
            idempotency
                .try_get::<Option<i32>, _>("response_status")
                .map_err(db)?,
            idempotency
                .try_get::<Option<Value>, _>("response_body")
                .map_err(db)?,
        )
    {
        transaction.commit().await.map_err(db)?;
        return Ok(Output {
            status: status as u16,
            media_type: if status == 204 {
                ""
            } else {
                "application/json"
            },
            body: response,
            replay: true,
        });
    }

    // The idempotency receipt is resolved before any canonical aggregate read
    // or mutation.  A replay therefore neither increments a version nor
    // depends on the resource still being readable after the original commit.
    let previous_case_state = if operation.id == "transitionCase" {
        let case_id =
            uuid_value(payload_object, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
        Some(
            sqlx::query_scalar::<_, String>(
                "SELECT investigation_state::text FROM editorial.cases WHERE id=$1 FOR UPDATE",
            )
            .bind(case_id)
            .fetch_optional(&mut *transaction)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?,
        )
    } else {
        None
    };
    let mut canonical_payload = payload_object.clone();
    for (name, value) in request.match_info().iter() {
        canonical_payload
            .entry(name.to_owned())
            .or_insert_with(|| Value::String(value.to_owned()));
    }
    let canonical_version =
        canonical_guard(operation.id, &canonical_payload, actor_id, &mut transaction).await?;

    let resource_type = resource_type(operation.id);
    let (resource_id, _) = resource_identity(operation.id, request, payload_object)?;
    let expected_version = payload_object
        .get("expectedVersion")
        .and_then(Value::as_i64);
    let persisted_id = resource_id;
    let version =
        canonical_version.unwrap_or_else(|| expected_version.map_or(1, |value| value + 1));
    let mut data = payload.clone();
    let status = command_status(operation.id, payload_object);
    let occurred_at = OffsetDateTime::now_utc();
    let occurred_text = occurred_at
        .format(&Rfc3339)
        .map_err(|_| ServiceError::Persistence)?;
    let object = data.as_object_mut().ok_or(ServiceError::InvalidRequest)?;
    object.insert("id".into(), json!(persisted_id));
    object.insert("resourceId".into(), json!(persisted_id));
    object.insert("resourceType".into(), json!(resource_type));
    object.insert("status".into(), json!(status));
    object.insert("version".into(), json!(version));
    object.insert("updatedAt".into(), json!(occurred_text));
    object.insert("updatedBy".into(), json!(actor_id));

    apply_specialized(
        operation.id,
        payload_object,
        persisted_id,
        actor_id,
        field_keys,
        &mut transaction,
    )
    .await?;

    if operation.id == "scheduleRuleActivation" {
        let rule_version_id =
            uuid_value(payload_object, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
        let effective_at =
            timestamp_value(payload_object, "effectiveAt")?.ok_or(ServiceError::InvalidRequest)?;
        enqueue_runtime_job(
            &mut transaction,
            "RULE_ACTIVATION",
            "scheduler",
            json!({
                "actorId": actor_id,
                "requestId": request_id,
                "ruleVersionId": rule_version_id,
            }),
            format!("rule-activation:{rule_version_id}:{request_id}"),
        )
        .await?;
        sqlx::query(
            "UPDATE ops.jobs SET run_after=$2 WHERE job_type='RULE_ACTIVATION' AND dedupe_key=$1",
        )
        .bind(format!("rule-activation:{rule_version_id}:{request_id}"))
        .bind(effective_at)
        .execute(&mut *transaction)
        .await
        .map_err(db)?;
    }

    let audit_event_id = sqlx::query_scalar::<_, Uuid>(
        "SELECT ops.append_audit_event($1,'USER',$2,$3,$4,$5,$6,$7,'SUCCESS',NULL,$8,$9)",
    )
    .bind(format!("control:{resource_type}:{persisted_id}"))
    .bind(actor_id.to_string())
    .bind(session_id)
    .bind(format!("command.{}", operation.id))
    .bind(resource_type)
    .bind(persisted_id.to_string())
    .bind(operation.capability)
    .bind(request_id)
    .bind(
        json!({"resourceVersion":version,"operationId":operation.id,"requestSha256":request_hash}),
    )
    .fetch_one(&mut *transaction)
    .await
    .map_err(db)?;
    let receipt_data = json!({
        "id":persisted_id,
        "resourceId":persisted_id,
        "resourceVersion":version,
        "version":version,
        "status":"completed",
        "operationId":operation.id,
        "requestId":request_id,
        "aggregateId":persisted_id.to_string(),
        "aggregateVersion":version,
        "auditEventId":audit_event_id,
        "acceptedAt":occurred_text,
        "data":data,
        "links":[],
    });
    let response = response_for(operation, &receipt_data)?;
    let status_code = operation.success_status;
    let candidates = event_candidates(
        &payload,
        EventCandidateContext {
            operation: operation.id,
            actor_id,
            request_id,
            resource_id: persisted_id,
            resource_version: version,
            occurred_at: &occurred_text,
            previous_case_state: previous_case_state.as_deref(),
        },
    )?;
    for event_type in producer_events(operation.id) {
        let event_payload =
            project_payload(event_type, &candidates).map_err(|_| ServiceError::InvalidRequest)?;
        if requires_outbox(event_type) {
            sqlx::query("SELECT ops.enqueue_outbox($1,$2,$3,$4,$5,$6)")
                .bind(resource_type)
                .bind(persisted_id.to_string())
                .bind(version)
                .bind(event_type)
                .bind(event_payload)
                .bind(occurred_at)
                .fetch_one(&mut *transaction)
                .await
                .map_err(db)?;
        }
    }
    sqlx::query("UPDATE ops.idempotency_keys SET response_status=$3,response_body=$4,resource_type=$5,resource_id=$6 WHERE scope=$1 AND key_hash=$2")
        .bind(&scope).bind(&key_hash).bind(i32::from(status_code)).bind(&response).bind(resource_type).bind(persisted_id.to_string())
        .execute(&mut *transaction).await.map_err(db)?;
    transaction.commit().await.map_err(db)?;
    Ok(Output {
        status: status_code,
        media_type: if status_code == 204 {
            ""
        } else {
            "application/json"
        },
        body: response,
        replay: false,
    })
}

async fn canonical_guard(
    operation: &str,
    payload: &Map<String, Value>,
    actor: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Option<i64>, ServiceError> {
    let catalog = CONCURRENCY.get_or_init(|| {
        serde_json::from_str(CONCURRENCY_JSON)
            .expect("embedded optimistic concurrency catalog must be valid")
    });
    let Some(contract) = catalog
        .contracts
        .iter()
        .find(|contract| contract.operation_id == operation)
    else {
        return Ok(None);
    };
    let expected = payload
        .get(&contract.version_field)
        .and_then(Value::as_i64)
        .ok_or(ServiceError::InvalidRequest)?;
    if expected < 1 {
        return Err(ServiceError::InvalidRequest);
    }
    let version_column = contract
        .guard_columns
        .iter()
        .find(|column| matches!(column.as_str(), "version" | "row_version"))
        .ok_or(ServiceError::Persistence)?;
    let identity_column = contract
        .guard_columns
        .iter()
        .find(|column| {
            !matches!(
                column.as_str(),
                "version" | "row_version" | "status" | "user_id"
            )
        })
        .ok_or(ServiceError::Persistence)?;
    for identifier in [&contract.guard_relation, version_column, identity_column] {
        if !safe_sql_identifier(identifier) {
            return Err(ServiceError::Persistence);
        }
    }
    let identity = canonical_identity(operation, contract, payload, transaction).await?;
    let owner_guard = contract
        .guard_columns
        .iter()
        .any(|column| column == "user_id");
    let status_guard = canonical_status_guard(operation);
    let owner_predicate = if owner_guard { " AND user_id=$3" } else { "" };
    let status_predicate = status_guard
        .map(|status| format!(" AND status::text='{}'", status.replace('\'', "''")))
        .unwrap_or_default();
    let sql = format!(
        "UPDATE {relation} SET {version}={version}+1 WHERE {identity_column}::text=$1 AND {version}=$2{owner_predicate}{status_predicate} RETURNING {version}",
        relation = contract.guard_relation,
        version = version_column,
    );
    let mut query = sqlx::query_scalar::<_, i64>(AssertSqlSafe(sql.as_str()))
        .bind(&identity)
        .bind(expected);
    if owner_guard {
        query = query.bind(actor);
    }
    if let Some(version) = query.fetch_optional(&mut **transaction).await.map_err(db)? {
        return Ok(Some(version));
    }
    let probe = format!(
        "SELECT EXISTS(SELECT 1 FROM {relation} WHERE {identity_column}::text=$1{owner_predicate})",
        relation = contract.guard_relation,
    );
    let mut query = sqlx::query_scalar::<_, bool>(AssertSqlSafe(probe.as_str())).bind(&identity);
    if owner_guard {
        query = query.bind(actor);
    }
    if query.fetch_one(&mut **transaction).await.map_err(db)? {
        Err(ServiceError::VersionConflict)
    } else {
        Err(ServiceError::NotFound)
    }
}

async fn canonical_identity(
    operation: &str,
    contract: &ConcurrencyContract,
    payload: &Map<String, Value>,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<String, ServiceError> {
    if matches!(
        operation,
        "createCorrection" | "createRetractionDraft" | "placeTemporaryRestriction"
    ) {
        let publication =
            uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
        let case_id = sqlx::query_scalar::<_, Uuid>(
            "SELECT case_id FROM editorial.publication_revisions WHERE id=$1",
        )
        .bind(publication)
        .fetch_optional(&mut **transaction)
        .await
        .map_err(db)?
        .ok_or(ServiceError::NotFound)?;
        return Ok(case_id.to_string());
    }
    let placeholder = contract
        .request_placeholders
        .iter()
        .find(|name| *name != &contract.version_field)
        .ok_or(ServiceError::InvalidRequest)?;
    let value = payload
        .get(placeholder)
        .ok_or(ServiceError::InvalidRequest)?;
    match value {
        Value::String(value) if !value.is_empty() => Ok(value.clone()),
        Value::Number(value) => Ok(value.to_string()),
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn canonical_status_guard(operation: &str) -> Option<&'static str> {
    match operation {
        "acknowledgeSourceIncident" => Some("OPEN"),
        "acceptAgentSuggestion" | "rejectAgentSuggestion" => Some("PENDING"),
        "pauseBackfill" => Some("RUNNING"),
        "resolveCorrectionRequest" => Some("REVIEW"),
        "saveResponseRequestDraft" => Some("DRAFT"),
        _ => None,
    }
}

fn safe_sql_identifier(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.'))
}

async fn query(
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

async fn canonical_query(
    operation: &str,
    parameters: &BTreeMap<String, String>,
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match operation {
        "getCurrentUserCapabilities" => Ok(json!({
            "id":claims.sub,"status":"ACTIVE","data":{"capabilities":claims.capabilities,
            "rolesVersion":claims.roles_version},"links":[]
        })),
        "getCurrentAccount" => {
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
        "getAgentRun" => {
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
        "getAuditExport" => {
            let id = query_uuid(parameters, "auditExportId")?;
            sqlx::query_scalar::<_, Value>(
                "SELECT jsonb_build_object('id',id,'status',status,'format',format,'scope',scope, \
                 'from',from_at,'to',to_at,'objectType',object_type,'objectId',object_id, \
                 'watermarkPolicy',watermark_policy,'createdAt',created_at,'startedAt',started_at, \
                 'completedAt',completed_at,'expiresAt',expires_at,'rowCount',row_count, \
                 'contentSha256',content_sha256,'downloadUrl',CASE WHEN object_key IS NULL THEN NULL \
                   ELSE '/v1/internal/audit-exports/'||id::text||'/download' END, \
                 'failureCode',failure_code,'links','[]'::jsonb) \
                 FROM ops.audit_exports WHERE id=$1",
            )
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)
        }
        "getCaseWorkspaceOverview"
        | "getInternalCase"
        | "getResponseRequestComposer"
        | "getReviewReadiness" => case_query(operation, parameters, pool).await,
        "getCorrectionWorkspace" => {
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
        "getRuleEvaluation" => {
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
        "getSchemaDrift" => schema_drift_query(parameters, pool).await,
        "getSignalTriageView" => signal_query(parameters, pool).await,
        "getSourceRun" => source_run_query(parameters, pool).await,
        "getUserAccessDetail" => user_access_query(parameters, pool).await,
        "estimateBackfill" => estimate_backfill_query(parameters, pool).await,
        "getBudgetOverview" => budget_query(pool).await,
        "downloadSourceRunReport" => source_run_download(parameters, pool).await,
        "exportCostReport" => cost_export_query(parameters, pool).await,
        "listCaseAuditEvents" | "searchAuditEvents" => audit_query(pool, parameters).await,
        _ if operation.starts_with("list") || operation == "searchInternalRecords" => {
            canonical_list_query(operation, parameters, claims, pool).await
        }
        _ => Err(ServiceError::Persistence),
    }
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

async fn case_query(
    operation: &str,
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "caseId")?;
    let case: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'slug',public_slug,'title',title, \
         'investigationState',investigation_state::text,'publicationState',publication_state::text, \
         'resolutionCode',resolution_code::text,'summary',summary,'priority',priority, \
         'leadInvestigatorId',lead_investigator_id,'editorId',editor_id, \
         'legalReviewRequired',legal_review_required,'currentReviewSnapshotId',current_review_snapshot_id, \
         'currentPublicationRevision',current_publication_revision,'version',version, \
         'createdAt',created_at,'updatedAt',updated_at) FROM editorial.cases WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    if operation == "getInternalCase" {
        return Ok(envelope(id, "READY", case));
    }
    if operation == "getResponseRequestComposer" {
        let drafts: Value = sqlx::query_scalar(
            "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'partyType',party_type, \
             'partyName',party_name,'questions',questions,'requestedPublicationScope', \
             requested_publication_scope,'dueAt',due_at,'status',status,'version',version) \
             ORDER BY created_at DESC),'[]'::jsonb) FROM editorial.response_requests WHERE case_id=$1",
        )
        .bind(id)
        .fetch_one(pool)
        .await
        .map_err(db)?;
        return Ok(envelope(
            id,
            "READY",
            json!({"case":case,"requests":drafts}),
        ));
    }
    let facts: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'claimType',claim_type::text, \
         'text',text,'limitations',limitations,'validationStatus',validation_status,'version',version) \
         ORDER BY created_at),'[]'::jsonb) FROM editorial.claims WHERE case_id=$1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let response_counts: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('requestCount',count(*),'sentCount',count(*) FILTER (WHERE status='SENT'), \
         'submittedCount',count(*) FILTER (WHERE status='SUBMITTED'),'pendingVerificationCount', \
         (SELECT count(*) FROM editorial.responses WHERE case_id=$1 AND verified_at IS NULL), \
         'blockers','[]'::jsonb) FROM editorial.response_requests WHERE case_id=$1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    if operation == "getReviewReadiness" {
        let blockers: Value = sqlx::query_scalar(
            "SELECT COALESCE(jsonb_agg(blocker),'[]'::jsonb) FROM ( \
             SELECT jsonb_build_object('code','CLAIM_NOT_VALIDATED','objectId',id) blocker \
             FROM editorial.claims WHERE case_id=$1 AND validation_status<>'VALID' \
             UNION ALL SELECT jsonb_build_object('code','EVIDENCE_NOT_VERIFIED','objectId',id) \
             FROM editorial.evidence WHERE case_id=$1 AND verification_status<>'VERIFIED') b",
        )
        .bind(id)
        .fetch_one(pool)
        .await
        .map_err(db)?;
        let status = if blockers.as_array().is_some_and(Vec::is_empty) {
            "READY"
        } else {
            "BLOCKED"
        };
        return Ok(envelope(
            id,
            status,
            json!({"case":case,"claims":facts,"responseStatus":response_counts,"blockers":blockers}),
        ));
    }
    let assignments: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'objectType',object_type, \
         'objectId',object_id,'assigneeUserId',assignee_user_id,'assignedBy',assigned_by, \
         'reason',reason,'active',active,'assignedAt',assigned_at) \
         ORDER BY assigned_at DESC),'[]'::jsonb) FROM editorial.assignments \
         WHERE object_type='CASE' AND object_id=$1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let save_version = case.get("version").cloned().unwrap_or(json!(1));
    Ok(
        json!({"case":case,"confirmedFacts":facts,"criticalUnknowns":[],
        "responseStatus":response_counts,"blockers":[],"nextRequiredActions":[],
        "assignments":assignments,"activity":[],"saveVersion":save_version}),
    )
}

async fn evidence_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "evidenceId")?;
    let evidence: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'caseId',case_id,'evidenceType',evidence_type, \
         'title',title,'description',description,'sourceDocumentId',source_document_id, \
         'sourceUrl',source_url,'sourceLocator',source_locator,'contentSha256',content_sha256, \
         'classification',classification::text,'verificationStatus',verification_status, \
         'verifiedBy',verified_by,'verifiedAt',verified_at,'publicExcerpt',redacted_public_excerpt, \
         'version',version) FROM editorial.evidence WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let claims: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('claimId',claim_id,'citationLabel', \
         citation_label,'citationOrder',citation_order,'supports',supports) ORDER BY citation_order), \
         '[]'::jsonb) FROM editorial.claim_evidence WHERE evidence_id=$1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let redactions: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'ranges',ranges,'redactionType', \
         redaction_type,'reason',reason,'replacementText',replacement_text,'status',status) \
         ORDER BY created_at),'[]'::jsonb) FROM editorial.evidence_redactions WHERE evidence_id=$1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    Ok(
        json!({"evidence":evidence,"sourceContext":{},"linkedClaims":claims,
        "verification":{},"redactions":redactions,"provenance":{},"blockers":[]}),
    )
}

async fn dashboard_query(claims: &ActorClaims, pool: &PgPool) -> Result<Value, ServiceError> {
    let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let counts: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object( \
         'incidents',(SELECT count(*) FROM ops.source_incidents WHERE status='OPEN'), \
         'myTasks',(SELECT count(*) FROM ops.tasks WHERE assignee_user_id=$1 AND status<>'DONE'), \
         'overdueTasks',(SELECT count(*) FROM ops.tasks WHERE due_at<clock_timestamp() AND status<>'DONE'), \
         'reviewQueue',(SELECT count(*) FROM editorial.review_assignments WHERE status IN ('ASSIGNED','IN_PROGRESS')), \
         'failedJobs',(SELECT count(*) FROM ops.jobs WHERE status IN ('FAILED','DEAD_LETTER')), \
         'unreadNotifications',(SELECT count(*) FROM ops.notifications WHERE user_id=$1 AND read_at IS NULL))",
    )
    .bind(actor)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    Ok(json!({
        "incidents":counts.get("incidents").cloned().unwrap_or(json!(0)),
        "myTasks":counts.get("myTasks").cloned().unwrap_or(json!(0)),
        "overdueTasks":counts.get("overdueTasks").cloned().unwrap_or(json!(0)),
        "reviewQueue":counts.get("reviewQueue").cloned().unwrap_or(json!(0)),
        "sourceHealth":[],
        "jobHealth":counts.get("failedJobs").cloned().unwrap_or(json!(0)),
        "budget":{},
        "notifications":counts.get("unreadNotifications").cloned().unwrap_or(json!(0))
    }))
}

async fn source_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let source = parameters
        .get("sourceId")
        .filter(|value| !value.is_empty())
        .ok_or(ServiceError::InvalidRequest)?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('sourceId',source_id,'displayName',display_name, \
         'connectorType',connector_type,'ownerTeam',owner_team,'enabled',enabled, \
         'scheduleCron',schedule_cron,'baseUrl',base_url,'legalStatus',legal_status, \
         'configuration',configuration,'version',version,'updatedAt',updated_at) \
         FROM ops.source_registry WHERE source_id=$1",
    )
    .bind(source)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(
        stable_uuid("source", source),
        if row.get("enabled").and_then(Value::as_bool) == Some(true) {
            "ACTIVE"
        } else {
            "PAUSED"
        },
        row,
    ))
}

async fn job_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "jobId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'jobType',job_type,'queue',queue,'status',status::text, \
         'priority',priority,'payload',payload,'runAfter',run_after,'leaseOwner',lease_owner, \
         'leaseExpiresAt',lease_expires_at,'fencingToken',fencing_token,'attemptCount',attempt_count, \
         'maxAttempts',max_attempts,'lastErrorCode',last_error_code,'lastErrorDetail',last_error_detail, \
         'version',version,'createdAt',created_at,'updatedAt',updated_at,'completedAt',completed_at) \
         FROM ops.jobs WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn operations_query(pool: &PgPool) -> Result<Value, ServiceError> {
    let queues: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('queueName',q.queue, \
         'queued',q.queued,'running',q.running,'failed',q.failed)),'[]'::jsonb) FROM ( \
         SELECT queue,count(*) FILTER (WHERE status='QUEUED') queued, \
         count(*) FILTER (WHERE status IN ('LEASED','RUNNING')) running, \
         count(*) FILTER (WHERE status IN ('FAILED','DEAD_LETTER')) failed \
         FROM ops.jobs GROUP BY queue ORDER BY queue) q",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let sources: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('sourceId',source_id,'enabled',enabled, \
         'legalStatus',legal_status) ORDER BY source_id),'[]'::jsonb) FROM ops.source_registry",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let incidents: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'sourceId',source_id, \
         'severity',severity::text,'type',incident_type,'summary',summary,'status',status) \
         ORDER BY created_at DESC),'[]'::jsonb) FROM ops.source_incidents WHERE status<>'RESOLVED'",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?;
    Ok(
        json!({"systemStatus":"OPERATIONAL","services":[],"queues":queues,
        "sources":sources,"incidents":incidents,"telemetryGaps":[],"recentActions":[]}),
    )
}

async fn publication_preview_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let snapshot = query_uuid(parameters, "reviewSnapshotId")?;
    let row = sqlx::query(
        "SELECT preview_sha256,preview_payload,expires_at FROM editorial.publication_previews \
         WHERE case_id=$1 AND review_snapshot_id=$2 AND expires_at>clock_timestamp() \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(case_id)
    .bind(snapshot)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"previewHash":row.try_get::<String,_>("preview_sha256").map_err(db)?.trim(),
        "caseId":case_id,"snapshotId":snapshot,
        "publicPayload":row.try_get::<Value,_>("preview_payload").map_err(db)?,
        "validation":[],"renderedRoutes":[],
        "expiresAt":format_time(row.try_get("expires_at").map_err(db)?)?}),
    )
}

async fn publication_receipt_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "publicationId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',r.id,'caseId',r.case_id,'revision',r.revision, \
         'state',r.state::text,'reviewSnapshotId',r.review_snapshot_id, \
         'publicPayloadSha256',r.public_payload_sha256,'previewSha256',r.preview_sha256, \
         'publishedBy',r.published_by,'publishedAt',r.published_at, \
         'supersedesRevision',r.supersedes_revision,'reason',r.reason) \
         FROM editorial.publication_revisions r WHERE r.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn publish_confirmation_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let snapshot = query_uuid(parameters, "reviewSnapshotId")?;
    let row = sqlx::query(
        "SELECT c.version,c.current_review_snapshot_id,s.snapshot_sha256,s.unresolved_blockers, \
         EXISTS(SELECT 1 FROM editorial.review_decisions d WHERE d.review_snapshot_id=s.id \
           AND d.decision='APPROVE' AND d.reviewer_id<>s.created_by) approved, \
         EXISTS(SELECT 1 FROM ops.kill_switches WHERE state='ACTIVE' \
           AND (expires_at IS NULL OR expires_at>clock_timestamp())) kill_switch \
         FROM editorial.cases c JOIN editorial.review_snapshots s ON s.id=$2 AND s.case_id=c.id \
         WHERE c.id=$1",
    )
    .bind(case_id)
    .bind(snapshot)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let current: Option<Uuid> = row.try_get("current_review_snapshot_id").map_err(db)?;
    let approved: bool = row.try_get("approved").map_err(db)?;
    let kill_switch: bool = row.try_get("kill_switch").map_err(db)?;
    let unresolved: Value = row.try_get("unresolved_blockers").map_err(db)?;
    let ready = current == Some(snapshot)
        && approved
        && !kill_switch
        && unresolved.as_array().is_some_and(Vec::is_empty);
    Ok(envelope(
        case_id,
        if ready { "READY" } else { "BLOCKED" },
        json!({"caseId":case_id,"reviewSnapshotId":snapshot,
            "caseVersion":row.try_get::<i64,_>("version").map_err(db)?,
            "snapshotHash":row.try_get::<String,_>("snapshot_sha256").map_err(db)?.trim(),
            "humanApproval":approved,"killSwitchActive":kill_switch,
            "unresolvedBlockers":unresolved}),
    ))
}

async fn review_snapshot_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "reviewSnapshotId")?;
    let row = sqlx::query(
        "SELECT case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results, \
         unresolved_blockers,created_by,created_at FROM editorial.review_snapshots WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let payload: Value = row.try_get("snapshot_payload").map_err(db)?;
    Ok(
        json!({"snapshotId":id,"caseId":row.try_get::<Uuid,_>("case_id").map_err(db)?,
        "caseVersion":row.try_get::<i64,_>("case_version").map_err(db)?,
        "snapshotHash":row.try_get::<String,_>("snapshot_sha256").map_err(db)?.trim(),
        "createdAt":format_time(row.try_get("created_at").map_err(db)?)?,
        "createdBy":row.try_get::<Uuid,_>("created_by").map_err(db)?,
        "claims":payload.get("claimIds").cloned().unwrap_or(json!([])),
        "evidence":payload.get("evidenceIds").cloned().unwrap_or(json!([])),
        "responses":payload.get("responseIds").cloned().unwrap_or(json!([])),
        "automatedGates":row.try_get::<Value,_>("automated_gate_results").map_err(db)?,
        "independence":{},"unresolvedBlockers":row.try_get::<Value,_>("unresolved_blockers").map_err(db)?,
        "diffFromCurrent":[]}),
    )
}

async fn schema_drift_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "schemaDriftId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',d.id,'sourceId',d.source_id,'detectedAt',d.detected_at, \
         'fingerprintBefore',d.fingerprint_before,'fingerprintAfter',d.fingerprint_after, \
         'addedFields',d.added_fields,'removedFields',d.removed_fields,'changedFields',d.changed_fields, \
         'sampleDocumentIds',d.sample_document_ids,'status',d.status,'impact',d.impact,'version',d.version, \
         'mappings',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',m.id,'mappingVersion', \
           m.mapping_version,'mappingDigest',m.mapping_digest,'fieldMappings',m.field_mappings, \
           'status',m.status,'decisionReason',m.decision_reason) ORDER BY m.mapping_version) \
           FROM ops.schema_mappings m WHERE m.schema_drift_id=d.id),'[]'::jsonb)) \
         FROM ops.schema_drifts d WHERE d.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn signal_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "signalId")?;
    let signal: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',s.id,'ruleRunId',s.rule_run_id, \
         'ruleVersionId',s.rule_version_id,'signalType',s.signal_type,'targetType',s.target_type, \
         'targetId',s.target_id,'score',s.score,'severity',s.severity,'status',s.status::text, \
         'explanation',s.explanation,'calculation',s.calculation,'blockers',s.blockers, \
         'comparisonDigest',s.comparison_digest,'assignedUserId',s.assigned_user_id,'version',s.version) \
         FROM core.anomaly_signals s WHERE s.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"signal":signal,"triggerExplanation":signal.get("explanation").cloned().unwrap_or(json!({})),
        "dataQuality":{},"targetRecord":{},"duplicates":[],
        "blockers":signal.get("blockers").cloned().unwrap_or(json!([])),
        "recommendedActions":[],"auditSummary":{}}),
    )
}

async fn source_run_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "sourceRunId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'sourceId',source_id,'mode',mode,'status',status, \
         'checkpointBefore',checkpoint_before,'checkpointAfter',checkpoint_after,'recordsSeen',records_seen, \
         'recordsChanged',records_changed,'startedAt',started_at,'completedAt',completed_at, \
         'reportAvailable',report_object_key IS NOT NULL,'errorDetail',error_detail,'version',version, \
         'retryOfSourceRunId',retry_of_source_run_id,'requestedFrom',requested_from, \
         'requestedTo',requested_to,'requestReason',request_reason) FROM ops.source_runs WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn user_access_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "userId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',u.id,'email',u.email,'displayName',u.display_name, \
         'status',u.status,'rolesVersion',COALESCE((SELECT max(urv.version) FROM ops.user_roles urv \
           WHERE urv.user_id=u.id AND urv.revoked_at IS NULL),0),'version',u.version, \
         'roles',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',r.id,'code',r.code, \
           'name',r.name,'riskLevel',r.risk_level,'expiresAt',ur.expires_at) ORDER BY r.code) \
           FROM ops.user_roles ur JOIN ops.roles r ON r.id=ur.role_id \
           WHERE ur.user_id=u.id AND ur.revoked_at IS NULL),'[]'::jsonb), \
         'activeSessions',(SELECT count(*) FROM ops.sessions s WHERE s.user_id=u.id AND s.revoked_at IS NULL)) \
         FROM ops.users u WHERE u.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn estimate_backfill_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let source = parameters
        .get("sourceId")
        .filter(|value| !value.is_empty())
        .ok_or(ServiceError::InvalidRequest)?;
    let from = query_date(parameters, "from")?;
    let to = query_date(parameters, "to")?;
    if from > to {
        return Err(ServiceError::InvalidRequest);
    }
    let enabled: bool = sqlx::query_scalar(
        "SELECT enabled AND legal_status='APPROVED' FROM ops.source_registry WHERE source_id=$1",
    )
    .bind(source)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let history: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('historicalRuns',count(*),'historicalRecords', \
         COALESCE(sum(records_seen),0),'historicalChanges',COALESCE(sum(records_changed),0)) \
         FROM ops.source_runs WHERE source_id=$1",
    )
    .bind(source)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    Ok(envelope(
        stable_uuid("backfill-estimate", &format!("{source}:{from}:{to}")),
        if enabled { "READY" } else { "BLOCKED" },
        json!({"sourceId":source,"from":from.to_string(),"to":to.to_string(),"estimate":history}),
    ))
}

async fn budget_query(pool: &PgPool) -> Result<Value, ServiceError> {
    let limits: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('scope',scope,'dailyLimit',daily_limit::text, \
         'monthlyLimit',monthly_limit::text,'currency',currency,'version',version) ORDER BY scope), \
         '[]'::jsonb) FROM ops.budget_limits",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let spend: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('totalActualCost',COALESCE(sum(actual_cost),0)::text, \
         'queuedMaxCost',COALESCE(sum(max_cost) FILTER (WHERE status IN ('QUEUED','RUNNING')),0)::text) \
         FROM ops.agent_runs",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?;
    Ok(envelope(
        stable_uuid("budget", "overview"),
        "READY",
        json!({"limits":limits,"spend":spend}),
    ))
}

async fn source_run_download(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "sourceRunId")?;
    let available: bool = sqlx::query_scalar(
        "SELECT status='SUCCEEDED' AND report_object_key IS NOT NULL FROM ops.source_runs WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    if !available {
        return Err(ServiceError::NotFound);
    }
    Ok(json!({"id":id,"status":"READY","version":1}))
}

async fn cost_export_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let from = parameters.get("from").ok_or(ServiceError::InvalidRequest)?;
    let to = parameters.get("to").ok_or(ServiceError::InvalidRequest)?;
    let rows: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('runs',count(*),'actualCost',COALESCE(sum(actual_cost),0)::text, \
         'maxCost',COALESCE(sum(max_cost),0)::text) FROM ops.agent_runs \
         WHERE created_at >= $1::timestamptz AND created_at <= $2::timestamptz",
    )
    .bind(from)
    .bind(to)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let digest = sha256(&serde_json::to_vec(&rows).map_err(|_| ServiceError::Persistence)?);
    Ok(json!({"id":stable_uuid("cost-export",&digest),"status":"READY","version":1}))
}

fn query_date(parameters: &BTreeMap<String, String>, name: &str) -> Result<Date, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    parameters
        .get(name)
        .ok_or(ServiceError::InvalidRequest)
        .and_then(|value| Date::parse(value, &format).map_err(|_| ServiceError::InvalidRequest))
}

fn stable_uuid(namespace: &str, value: &str) -> Uuid {
    let digest = Sha256::digest(format!("gurine:{namespace}:{value}").as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

async fn canonical_list_query(
    operation: &str,
    parameters: &BTreeMap<String, String>,
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = match operation {
        "listCaseAgentRuns" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'agentType',agent_type,'objective',objective,'status',status,'maxCost',max_cost::text,'actualCost',actual_cost::text,'version',version,'createdAt',created_at) ORDER BY created_at DESC),'[]'::jsonb) FROM ops.agent_runs WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?
        }
        "listCaseClaims" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'claimType',claim_type::text,'text',text,'limitations',limitations,'validationStatus',validation_status,'version',version) ORDER BY created_at),'[]'::jsonb) FROM editorial.claims WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?
        }
        "listCaseCorrections" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'sourceRevision',source_revision,'targetRevision',target_revision,'summary',summary,'reason',reason,'status',status,'resolution',resolution,'version',version) ORDER BY created_at DESC),'[]'::jsonb) FROM editorial.corrections WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?
        }
        "listCaseEvidence" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'evidenceType',evidence_type,'title',title,'classification',classification::text,'verificationStatus',verification_status,'contentSha256',content_sha256,'version',version) ORDER BY created_at),'[]'::jsonb) FROM editorial.evidence WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?
        }
        "listCaseHypotheses" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'statement',statement,'status',status,'unknowns',unknowns,'version',version) ORDER BY created_at),'[]'::jsonb) FROM editorial.hypotheses WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?
        }
        "listCaseResponses" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'responseRequestId',response_request_id,'partyName',party_name,'submittedAt',submitted_at,'verifiedAt',verified_at,'publicExcerpt',public_excerpt,'publicationConsent',publication_consent,'editorialStatus',editorial_status,'version',version) ORDER BY submitted_at DESC),'[]'::jsonb) FROM editorial.responses WHERE case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?
        }
        "listCaseSignals" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'signalType',s.signal_type,'severity',s.severity,'status',s.status::text,'score',s.score,'version',s.version,'linkedAt',cs.linked_at) ORDER BY cs.linked_at DESC),'[]'::jsonb) FROM editorial.case_signals cs JOIN core.anomaly_signals s ON s.id=cs.signal_id WHERE cs.case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?
        }
        "listCaseTimeline" => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'occurredAt',occurred_at,'action',action,'actorId',actor_id,'outcome',outcome::text,'reason',reason,'details',details) ORDER BY occurred_at DESC),'[]'::jsonb) FROM ops.audit_events WHERE object_id=$1::text").bind(case_id.to_string()).fetch_one(pool).await.map_err(db)?
        }
        "listCorrectionQueue" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',x.id,'caseId',x.case_id,'caseTitle',c.title,'status',x.status,'summary',x.summary,'priority',x.priority,'assignedUserId',x.assigned_user_id,'version',x.version) ORDER BY x.updated_at DESC),'[]'::jsonb) FROM editorial.corrections x JOIN editorial.cases c ON c.id=x.case_id WHERE x.status IN ('DRAFT','REVIEW')").fetch_one(pool).await.map_err(db)?,
        "listInternalCases" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'slug',public_slug,'title',title,'investigationState',investigation_state::text,'publicationState',publication_state::text,'priority',priority,'leadInvestigatorId',lead_investigator_id,'version',version,'updatedAt',updated_at) ORDER BY updated_at DESC),'[]'::jsonb) FROM editorial.cases").fetch_one(pool).await.map_err(db)?,
        "listInternalNotifications" => {
            let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'notificationType',notification_type,'title',title,'body',body,'readAt',read_at,'version',version,'createdAt',created_at) ORDER BY created_at DESC),'[]'::jsonb) FROM ops.notifications WHERE user_id=$1").bind(actor).fetch_one(pool).await.map_err(db)?
        }
        "listInternalRules" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'ruleId',rule_id,'versionName',version,'name',name,'status',status,'effectiveAt',effective_at,'rowVersion',row_version) ORDER BY rule_id,created_at DESC),'[]'::jsonb) FROM core.rule_versions").fetch_one(pool).await.map_err(db)?,
        "listInternalSources" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('sourceId',source_id,'displayName',display_name,'connectorType',connector_type,'ownerTeam',owner_team,'enabled',enabled,'legalStatus',legal_status,'version',version,'updatedAt',updated_at) ORDER BY source_id),'[]'::jsonb) FROM ops.source_registry").fetch_one(pool).await.map_err(db)?,
        "listJobs" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'jobType',job_type,'queue',queue,'status',status::text,'priority',priority,'attemptCount',attempt_count,'maxAttempts',max_attempts,'version',version,'runAfter',run_after,'updatedAt',updated_at) ORDER BY created_at DESC),'[]'::jsonb) FROM ops.jobs").fetch_one(pool).await.map_err(db)?,
        "listKillSwitches" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'code',code,'scope',scope,'state',state::text,'reason',reason,'activatedAt',activated_at,'expiresAt',expires_at,'version',version) ORDER BY updated_at DESC),'[]'::jsonb) FROM ops.kill_switches").fetch_one(pool).await.map_err(db)?,
        "listMyTasks" => {
            let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'taskType',task_type,'objectType',object_type,'objectId',object_id,'title',title,'status',status,'priority',priority,'dueAt',due_at,'blockerCode',blocker_code,'version',version) ORDER BY due_at NULLS LAST,created_at),'[]'::jsonb) FROM ops.tasks WHERE assignee_user_id=$1").bind(actor).fetch_one(pool).await.map_err(db)?
        }
        "listProviders" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'providerType',provider_type,'name',name,'enabled',enabled,'routingPolicy',routing_policy,'dataRetentionPolicy',data_retention_policy,'lastConnectionTestAt',last_connection_test_at,'lastConnectionTestStatus',last_connection_test_status,'version',version) ORDER BY name),'[]'::jsonb) FROM ops.provider_configs").fetch_one(pool).await.map_err(db)?,
        "listReviewQueue" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',a.id,'caseId',a.case_id,'reviewSnapshotId',a.review_snapshot_id,'reviewerId',a.reviewer_id,'status',a.status::text,'dueAt',a.due_at,'version',a.version,'caseTitle',c.title) ORDER BY a.due_at NULLS LAST,a.created_at),'[]'::jsonb) FROM editorial.review_assignments a JOIN editorial.cases c ON c.id=a.case_id WHERE a.status IN ('ASSIGNED','IN_PROGRESS')").fetch_one(pool).await.map_err(db)?,
        "listRoleDefinitions" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'name',r.name,'description',r.description,'riskLevel',r.risk_level,'version',r.version,'capabilities',COALESCE((SELECT jsonb_agg(rc.capability_code ORDER BY rc.capability_code) FROM ops.role_capabilities rc WHERE rc.role_id=r.id),'[]'::jsonb)) ORDER BY r.code),'[]'::jsonb) FROM ops.roles r").fetch_one(pool).await.map_err(db)?,
        "listSignals" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'signalType',signal_type,'targetType',target_type,'targetId',target_id,'score',score,'severity',severity,'status',status::text,'assignedUserId',assigned_user_id,'version',version,'createdAt',created_at) ORDER BY created_at DESC),'[]'::jsonb) FROM core.anomaly_signals").fetch_one(pool).await.map_err(db)?,
        "listSourceRuns" => {
            let source = parameters.get("sourceId").ok_or(ServiceError::InvalidRequest)?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'sourceId',source_id,'mode',mode,'status',status,'recordsSeen',records_seen,'recordsChanged',records_changed,'version',version,'startedAt',started_at,'completedAt',completed_at) ORDER BY created_at DESC),'[]'::jsonb) FROM ops.source_runs WHERE source_id=$1").bind(source).fetch_one(pool).await.map_err(db)?
        }
        "listUsers" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',u.id,'email',u.email,'displayName',u.display_name,'status',u.status,'rolesVersion',COALESCE((SELECT max(ur.version) FROM ops.user_roles ur WHERE ur.user_id=u.id AND ur.revoked_at IS NULL),0),'version',u.version,'lastLoginAt',u.last_login_at) ORDER BY u.display_name),'[]'::jsonb) FROM ops.users u").fetch_one(pool).await.map_err(db)?,
        "listSavedViews" => {
            let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'name',name,'surface',surface,'query',query,'isDefault',is_default,'version',version,'createdAt',created_at,'updatedAt',updated_at) ORDER BY updated_at DESC),'[]'::jsonb) FROM ops.saved_views WHERE user_id=$1").bind(actor).fetch_one(pool).await.map_err(db)?
        }
        "searchInternalRecords" => {
            let query = parameters.get("q").filter(|value| !value.trim().is_empty()).ok_or(ServiceError::InvalidRequest)?;
            let pattern = format!("%{}%", query.replace('%', "\\%").replace('_', "\\_"));
            sqlx::query_scalar("SELECT COALESCE(jsonb_agg(item),'[]'::jsonb) FROM (SELECT jsonb_build_object('resultType','CASE','id',id,'title',title,'summary',summary) item,updated_at sort_at FROM editorial.cases WHERE title ILIKE $1 ESCAPE '\\' OR summary ILIKE $1 ESCAPE '\\' UNION ALL SELECT jsonb_build_object('resultType','EVIDENCE','id',id,'title',title,'summary',description),updated_at FROM editorial.evidence WHERE title ILIKE $1 ESCAPE '\\' OR description ILIKE $1 ESCAPE '\\' ORDER BY sort_at DESC LIMIT 100) results").bind(pattern).fetch_one(pool).await.map_err(db)?
        }
        _ => return Err(ServiceError::Persistence),
    };
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}

async fn audit_query(
    pool: &PgPool,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    let object_id = parameters
        .get("caseId")
        .or_else(|| parameters.get("objectId"));
    let rows=sqlx::query("SELECT id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability,outcome::text outcome,reason,request_id,details,event_hash,previous_event_hash FROM ops.audit_events WHERE ($1::text IS NULL OR object_id=$1) ORDER BY occurred_at DESC LIMIT 200")
        .bind(object_id).fetch_all(pool).await.map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        items.push(json!({"id":r.try_get::<Uuid,_>("id").map_err(db)?,"occurredAt":format_time(r.try_get("occurred_at").map_err(db)?)?,"actorType":r.try_get::<String,_>("actor_type").map_err(db)?,"actorId":r.try_get::<Option<String>,_>("actor_id").map_err(db)?,"action":r.try_get::<String,_>("action").map_err(db)?,"objectType":r.try_get::<Option<String>,_>("object_type").map_err(db)?,"objectId":r.try_get::<Option<String>,_>("object_id").map_err(db)?,"capability":r.try_get::<Option<String>,_>("capability").map_err(db)?,"outcome":r.try_get::<String,_>("outcome").map_err(db)?,"reason":r.try_get::<Option<String>,_>("reason").map_err(db)?,"requestId":r.try_get::<Uuid,_>("request_id").map_err(db)?,"details":r.try_get::<Value,_>("details").map_err(db)?,"eventHash":r.try_get::<String,_>("event_hash").map_err(db)?.trim(),"previousEventHash":r.try_get::<Option<String>,_>("previous_event_hash").map_err(db)?.map(|v|v.trim().to_owned())}));
    }
    Ok(
        json!({"items":items,"appliedFilters":parameters,"asOf":format_time(OffsetDateTime::now_utc())?}),
    )
}

async fn apply_specialized(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "acceptAgentSuggestion" | "rejectAgentSuggestion" => {
            let suggestion =
                uuid_value(payload, &["suggestionId"]).ok_or(ServiceError::InvalidRequest)?;
            let status = if operation == "acceptAgentSuggestion" {
                "ACCEPTED"
            } else {
                "REJECTED"
            };
            let changed = sqlx::query(
                "UPDATE ops.agent_suggestions SET status=$2,decision_reason=$3,decided_by=$4, \
                 decided_at=clock_timestamp() WHERE id=$1 AND status='PENDING'",
            )
            .bind(suggestion)
            .bind(status)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::VersionConflict);
            }
        }
        "activateRuleVersion" | "scheduleRuleActivation" => {
            let version =
                uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
            let digest = string_value(payload, "evaluationDigest")
                .filter(|value| is_sha256(value))
                .ok_or(ServiceError::InvalidRequest)?;
            let evaluated: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM core.rule_evaluations WHERE rule_version_id=$1 \
                 AND status='SUCCEEDED' AND result_digest=$2)",
            )
            .bind(version)
            .bind(digest)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if !evaluated {
                return Err(ServiceError::InvalidRequest);
            }
            let effective_at =
                timestamp_value(payload, "effectiveAt")?.ok_or(ServiceError::InvalidRequest)?;
            let rollout = if operation == "scheduleRuleActivation" {
                Some(string_value(payload, "rollout").ok_or(ServiceError::InvalidRequest)?)
            } else {
                Some("ALL")
            };
            if operation == "activateRuleVersion" && effective_at > OffsetDateTime::now_utc() {
                return Err(ServiceError::InvalidRequest);
            }
            if operation == "activateRuleVersion" {
                sqlx::query(
                    "UPDATE core.rule_versions SET status='RETIRED',retired_at=clock_timestamp() \
                     WHERE rule_id=(SELECT rule_id FROM core.rule_versions WHERE id=$1) \
                       AND status='ACTIVE' AND id<>$1",
                )
                .bind(version)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
            }
            let status = if operation == "activateRuleVersion" {
                "ACTIVE"
            } else {
                "SCHEDULED"
            };
            let changed = sqlx::query(
                "UPDATE core.rule_versions SET status=$2,effective_at=$3, \
                 activation_evaluation_digest=$4,activation_rollout=$5,activation_reason=$6 \
                 WHERE id=$1 AND status IN ('DRAFT','SHADOW','SCHEDULED')",
            )
            .bind(version)
            .bind(status)
            .bind(effective_at)
            .bind(digest)
            .bind(rollout)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::VersionConflict);
            }
        }
        "addClaim" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.claims(id,case_id,claim_type,text,limitations, \
                 validation_status,created_by) VALUES($1,$2,$3::editorial.claim_type,$4,$5,'DRAFT',$6)",
            )
            .bind(id)
            .bind(case_id)
            .bind(string_value(payload, "claimType").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "text").ok_or(ServiceError::InvalidRequest)?)
            .bind(payload.get("limitations").cloned().ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            replace_claim_relations(id, payload, tx).await?;
        }
        "addEvidence" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_document_id, \
                 source_url,source_locator,content_sha256,classification,verification_status, \
                 description,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8, \
                 $9::editorial.evidence_classification,'PENDING',$10,$11)",
            )
            .bind(id)
            .bind(case_id)
            .bind(string_value(payload, "evidenceType").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "title").ok_or(ServiceError::InvalidRequest)?)
            .bind(uuid_value(payload, &["sourceDocumentId"]))
            .bind(payload.get("sourceUrl").and_then(Value::as_str))
            .bind(string_value(payload, "locator").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "contentHash").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "classification").ok_or(ServiceError::InvalidRequest)?)
            .bind(payload.get("notes").and_then(Value::as_str))
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "assignCorrection" => {
            let correction =
                uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
            let assignee =
                uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed =
                sqlx::query("UPDATE editorial.corrections SET assigned_user_id=$2 WHERE id=$1")
                    .bind(correction)
                    .bind(assignee)
                    .execute(&mut **tx)
                    .await
                    .map_err(db)?
                    .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
            upsert_task(
                tx,
                "CORRECTION",
                correction,
                "Correction review",
                "OPEN",
                "HIGH",
                Some(assignee),
                actor,
                None,
            )
            .await?;
        }
        "assignReview" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let snapshot = uuid_value(payload, &["reviewSnapshotId"]);
            let reviewer =
                uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
            let assignment_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO editorial.review_assignments(id,case_id,review_snapshot_id,reviewer_id, \
                 status,assigned_by,assigned_at,due_at) \
                 VALUES($1,$2,$3,$4,'ASSIGNED',$5,clock_timestamp(),$6) \
                 ON CONFLICT(case_id,review_snapshot_id,reviewer_id) DO UPDATE SET \
                 status='ASSIGNED',assigned_by=EXCLUDED.assigned_by,assigned_at=clock_timestamp(), \
                 due_at=EXCLUDED.due_at,completed_at=NULL,version=editorial.review_assignments.version+1",
            )
            .bind(assignment_id)
            .bind(case_id)
            .bind(snapshot)
            .bind(reviewer)
            .bind(actor)
            .bind(timestamp_value(payload, "dueAt")?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            upsert_task(
                tx,
                "REVIEW",
                snapshot.unwrap_or(case_id),
                "Editorial review",
                "OPEN",
                "HIGH",
                Some(reviewer),
                actor,
                None,
            )
            .await?;
        }
        "createResponseRequest" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let email = normalized_email(
                string_value(payload, "recipientEmail").ok_or(ServiceError::InvalidRequest)?,
            )?;
            let encrypted = encrypt_control_field(
                field_keys,
                "editorial.response_requests",
                "recipient_email_encrypted",
                id,
                "email-address",
                email.as_bytes(),
            )?;
            sqlx::query(
                "INSERT INTO editorial.response_requests(id,case_id,party_type,party_name, \
                 recipient_email_hash,recipient_email_encrypted,questions, \
                 requested_publication_scope,due_at,status,created_by) \
                 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'DRAFT',$10)",
            )
            .bind(id)
            .bind(case_id)
            .bind(string_value(payload, "partyType").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "partyName").ok_or(ServiceError::InvalidRequest)?)
            .bind(sha256(email.as_bytes()))
            .bind(encrypted)
            .bind(
                payload
                    .get("questions")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(
                payload
                    .get("requestedPublicationScope")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(timestamp_value(payload, "dueAt")?.ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "createRuleVersionDraft" => {
            let rule_id = string_value(payload, "ruleId").ok_or(ServiceError::InvalidRequest)?;
            let version = payload
                .get("baseVersion")
                .and_then(Value::as_str)
                .map_or_else(
                    || format!("draft-{}", id.simple()),
                    |base| format!("{base}-draft-{}", id.simple()),
                );
            sqlx::query(
                "INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration, \
                 code_digest,status,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,'DRAFT',$8)",
            )
            .bind(id)
            .bind(rule_id)
            .bind(version)
            .bind(string_value(payload, "name").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "description").ok_or(ServiceError::InvalidRequest)?)
            .bind(
                payload
                    .get("configuration")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(
                string_value(payload, "implementationDigest")
                    .filter(|value| is_sha256(value))
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "createCorrection" => {
            let publication =
                uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
            let row = sqlx::query(
                "SELECT case_id,revision FROM editorial.publication_revisions WHERE id=$1",
            )
            .bind(publication)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?;
            sqlx::query(
                "INSERT INTO editorial.corrections(id,case_id,source_revision,summary,reason, \
                 affected_claim_ids,replacement_content,status,created_by) \
                 VALUES($1,$2,$3,$4,$5,$6,$7,'DRAFT',$8)",
            )
            .bind(id)
            .bind(row.try_get::<Uuid, _>("case_id").map_err(db)?)
            .bind(row.try_get::<i32, _>("revision").map_err(db)?)
            .bind(string_value(payload, "summary").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(
                payload
                    .get("affectedClaimIds")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(
                payload
                    .get("replacementContent")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "createEvidenceRedaction" => {
            let evidence =
                uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.evidence_redactions(id,evidence_id,ranges,redaction_type, \
                 reason,replacement_text,status,created_by) VALUES($1,$2,$3,$4,$5,$6,'DRAFT',$7)",
            )
            .bind(id)
            .bind(evidence)
            .bind(
                payload
                    .get("ranges")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(string_value(payload, "redactionType").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(payload.get("replacementText").and_then(Value::as_str))
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "createHypothesis" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.hypotheses(id,case_id,statement,status,unknowns,created_by) \
                 VALUES($1,$2,$3,'OPEN',$4,$5)",
            )
            .bind(id)
            .bind(case_id)
            .bind(string_value(payload, "statement").ok_or(ServiceError::InvalidRequest)?)
            .bind(
                payload
                    .get("unknowns")
                    .cloned()
                    .unwrap_or_else(|| json!([])),
            )
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            replace_hypothesis_relations(id, payload, actor, tx).await?;
        }
        "createRetractionDraft" => {
            let publication =
                uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
            let scope = match string_value(payload, "scope") {
                Some("full") | Some("FULL") => "FULL",
                Some("partial") | Some("PARTIAL") => "PARTIAL",
                _ => return Err(ServiceError::InvalidRequest),
            };
            let exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM editorial.publication_revisions WHERE id=$1)",
            )
            .bind(publication)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if !exists {
                return Err(ServiceError::NotFound);
            }
            sqlx::query(
                "INSERT INTO editorial.retraction_drafts(id,publication_revision_id,scope, \
                 affected_claim_ids,reason,status,created_by) VALUES($1,$2,$3,$4,$5,'DRAFT',$6)",
            )
            .bind(id)
            .bind(publication)
            .bind(scope)
            .bind(
                payload
                    .get("affectedClaimIds")
                    .cloned()
                    .unwrap_or_else(|| json!([])),
            )
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "createReviewSnapshot" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let claims = uuid_array(payload, "claimIds")?;
            let evidence = uuid_array(payload, "evidenceIds")?;
            let responses = payload
                .get("responseIds")
                .map(|_| uuid_array(payload, "responseIds"))
                .transpose()?
                .unwrap_or_default();
            let case_row = sqlx::query(
                "SELECT title,summary,investigation_state::text investigation_state, \
                 publication_state::text publication_state,version FROM editorial.cases WHERE id=$1",
            )
            .bind(case_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?;
            let invalid_claims: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM unnest($1::uuid[]) AS selected(id) \
                 LEFT JOIN editorial.claims c ON c.id=selected.id AND c.case_id=$2 \
                 WHERE c.id IS NULL",
            )
            .bind(&claims)
            .bind(case_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            let invalid_evidence: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM unnest($1::uuid[]) AS selected(id) \
                 LEFT JOIN editorial.evidence e ON e.id=selected.id AND e.case_id=$2 \
                 WHERE e.id IS NULL",
            )
            .bind(&evidence)
            .bind(case_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if invalid_claims != 0 || invalid_evidence != 0 {
                return Err(ServiceError::InvalidRequest);
            }
            let source_gate: Value = sqlx::query_scalar(
                "WITH grouped AS ( \
                   SELECT d.source_id,max(d.retrieved_at) retrieved_at,bool_and(d.status='PARSED') current, \
                     COALESCE(jsonb_agg(d.prompt_injection_flags ORDER BY d.retrieved_at) \
                       FILTER (WHERE d.prompt_injection_flags<>'[]'::jsonb),'[]'::jsonb) prompt_flags \
                   FROM editorial.evidence e JOIN raw.source_documents d ON d.id=e.source_document_id \
                   WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) GROUP BY d.source_id \
                 ) SELECT jsonb_build_object( \
                   'freshness',COALESCE(jsonb_object_agg(source_id,jsonb_build_object( \
                     'retrievedAt',retrieved_at,'status',CASE WHEN current THEN 'CURRENT' ELSE 'STALE' END, \
                     'promptInjectionFlags',prompt_flags)),'{}'::jsonb), \
                   'blockers',COALESCE(jsonb_agg(jsonb_build_object( \
                     'code',CASE WHEN NOT current THEN 'SOURCE_FRESHNESS_BLOCKED' \
                       ELSE 'PROMPT_INJECTION_FLAGGED' END,'sourceId',source_id)) \
                     FILTER (WHERE NOT current OR prompt_flags<>'[]'::jsonb),'[]'::jsonb)) \
                 FROM grouped",
            )
            .bind(case_id)
            .bind(&evidence)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            let freshness = source_gate
                .get("freshness")
                .cloned()
                .ok_or(ServiceError::Persistence)?;
            let blockers = source_gate
                .get("blockers")
                .cloned()
                .ok_or(ServiceError::Persistence)?;
            let source_freshness_valid = blockers.as_array().is_some_and(Vec::is_empty);
            let snapshot = json!({
                "caseId":case_id,
                "caseVersion":case_row.try_get::<i64,_>("version").map_err(db)?,
                "title":case_row.try_get::<String,_>("title").map_err(db)?,
                "summary":case_row.try_get::<Option<String>,_>("summary").map_err(db)?,
                "investigationState":case_row.try_get::<String,_>("investigation_state").map_err(db)?,
                "publicationState":case_row.try_get::<String,_>("publication_state").map_err(db)?,
                "claimIds":claims,
                "evidenceIds":evidence,
                "responseIds":responses,
                "sourceFreshness":freshness,
            });
            let digest =
                sha256(&serde_json::to_vec(&snapshot).map_err(|_| ServiceError::Persistence)?);
            sqlx::query(
                "INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256, \
                 snapshot_payload,automated_gate_results,unresolved_blockers,created_by) \
                 VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
            )
            .bind(id)
            .bind(case_id)
            .bind(
                snapshot
                    .get("caseVersion")
                    .and_then(Value::as_i64)
                    .ok_or(ServiceError::Persistence)?,
            )
            .bind(digest)
            .bind(snapshot)
            .bind(json!({"selectedClaimsValid":invalid_claims==0,
                "selectedEvidenceValid":invalid_evidence==0,
                "sourceFreshnessValid":source_freshness_valid}))
            .bind(blockers)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            sqlx::query("UPDATE editorial.cases SET current_review_snapshot_id=$2 WHERE id=$1")
                .bind(case_id)
                .bind(id)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
        }
        "approveResponseExcerpt" => {
            let response =
                uuid_value(payload, &["responseId"]).ok_or(ServiceError::InvalidRequest)?;
            let requested = string_value(payload, "excerptHash")
                .filter(|value| is_sha256(value))
                .ok_or(ServiceError::InvalidRequest)?;
            let excerpt: Option<String> =
                sqlx::query_scalar("SELECT public_excerpt FROM editorial.responses WHERE id=$1")
                    .bind(response)
                    .fetch_optional(&mut **tx)
                    .await
                    .map_err(db)?
                    .ok_or(ServiceError::NotFound)?;
            let excerpt = excerpt.ok_or(ServiceError::InvalidRequest)?;
            if sha256(excerpt.as_bytes()) != requested {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "UPDATE editorial.responses SET public_excerpt_sha256=$2,excerpt_approved_by=$3, \
                 excerpt_approved_at=clock_timestamp(),editorial_status= \
                 CASE WHEN editorial_status='PENDING' THEN 'ACCEPTED' ELSE editorial_status END \
                 WHERE id=$1",
            )
            .bind(response)
            .bind(requested)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "approveSchemaMapping" | "rejectSchemaMapping" => {
            let drift =
                uuid_value(payload, &["schemaDriftId"]).ok_or(ServiceError::InvalidRequest)?;
            let mapping_version = payload
                .get("mappingVersion")
                .and_then(Value::as_i64)
                .and_then(|value| i32::try_from(value).ok())
                .filter(|value| *value > 0)
                .ok_or(ServiceError::InvalidRequest)?;
            let digest = string_value(payload, "mappingDigest")
                .filter(|value| is_sha256(value))
                .ok_or(ServiceError::InvalidRequest)?;
            let approved = operation == "approveSchemaMapping";
            let mappings = if approved {
                payload
                    .get("fieldMappings")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?
            } else {
                json!([])
            };
            sqlx::query(
                "INSERT INTO ops.schema_mappings(schema_drift_id,mapping_version,mapping_digest, \
                 field_mappings,status,proposed_by,decided_by,decision_reason,decided_at) \
                 VALUES($1,$2,$3,$4,$5,$6,$6,$7,clock_timestamp())",
            )
            .bind(drift)
            .bind(mapping_version)
            .bind(digest)
            .bind(mappings)
            .bind(if approved { "APPROVED" } else { "REJECTED" })
            .bind(actor)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            sqlx::query("UPDATE ops.schema_drifts SET status=$2 WHERE id=$1")
                .bind(drift)
                .bind(if approved { "APPROVED" } else { "REJECTED" })
                .execute(&mut **tx)
                .await
                .map_err(db)?;
        }
        "assignCase" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let assignee =
                uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query("UPDATE editorial.cases SET lead_investigator_id=$2 WHERE id=$1")
                .bind(case_id)
                .bind(assignee)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
            upsert_task(
                tx,
                "CASE",
                case_id,
                "Case investigation",
                "OPEN",
                "HIGH",
                Some(assignee),
                actor,
                payload.get("reason").and_then(Value::as_str),
            )
            .await?;
        }
        "assignSignal" => {
            let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
            let assignee =
                uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "UPDATE core.anomaly_signals SET assigned_user_id=$2,status='ASSIGNED' WHERE id=$1",
            )
            .bind(signal)
            .bind(assignee)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            upsert_task(
                tx,
                "SIGNAL",
                signal,
                "Signal triage",
                "OPEN",
                "HIGH",
                Some(assignee),
                actor,
                payload.get("reason").and_then(Value::as_str),
            )
            .await?;
        }
        "acknowledgeSourceIncident" => {
            let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE ops.source_incidents SET status='ACKNOWLEDGED',acknowledged_by=$2, \
                 acknowledged_at=clock_timestamp() WHERE source_id=$1 AND status='OPEN'",
            )
            .bind(source)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "createAccessRequest" => {
            sqlx::query(
                "INSERT INTO ops.access_requests(id,requester_user_id,requested_role_codes,reason, \
                 requested_until,status) VALUES($1,$2,$3,$4,$5,'PENDING')",
            )
            .bind(id)
            .bind(actor)
            .bind(
                payload
                    .get("requestedRoleCodes")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(timestamp_value(payload, "requestedUntil")?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "createSavedView" => {
            if payload.get("isDefault").and_then(Value::as_bool) == Some(true) {
                sqlx::query(
                    "UPDATE ops.saved_views SET is_default=false WHERE user_id=$1 AND surface=$2",
                )
                .bind(actor)
                .bind(string_value(payload, "surface").ok_or(ServiceError::InvalidRequest)?)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
            }
            sqlx::query(
                "INSERT INTO ops.saved_views(id,user_id,name,surface,query,is_default) \
                 VALUES($1,$2,$3,$4,$5,$6)",
            )
            .bind(id)
            .bind(actor)
            .bind(string_value(payload, "name").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "surface").ok_or(ServiceError::InvalidRequest)?)
            .bind(
                payload
                    .get("query")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(
                payload
                    .get("isDefault")
                    .and_then(Value::as_bool)
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "updateSavedView" => {
            let target = uuid_value(payload, &["savedViewId", "id"]).unwrap_or(id);
            if payload.get("isDefault").and_then(Value::as_bool) == Some(true) {
                let surface: String = sqlx::query_scalar(
                    "SELECT surface FROM ops.saved_views WHERE id=$1 AND user_id=$2",
                )
                .bind(target)
                .bind(actor)
                .fetch_optional(&mut **tx)
                .await
                .map_err(db)?
                .ok_or(ServiceError::NotFound)?;
                sqlx::query("UPDATE ops.saved_views SET is_default=false WHERE user_id=$1 AND surface=$2 AND id<>$3")
                    .bind(actor).bind(surface).bind(target).execute(&mut **tx).await.map_err(db)?;
            }
            let changed = sqlx::query(
                "UPDATE ops.saved_views SET name=COALESCE($3,name),query=COALESCE($4,query), \
                 is_default=COALESCE($5,is_default) WHERE id=$1 AND user_id=$2",
            )
            .bind(target)
            .bind(actor)
            .bind(payload.get("name").and_then(Value::as_str))
            .bind(payload.get("query").cloned())
            .bind(payload.get("isDefault").and_then(Value::as_bool))
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "deleteSavedView" => {
            let changed = sqlx::query("DELETE FROM ops.saved_views WHERE id=$1 AND user_id=$2")
                .bind(id)
                .bind(actor)
                .execute(&mut **tx)
                .await
                .map_err(db)?
                .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "disableProviderRouting" => {
            let changed = sqlx::query(
                "UPDATE ops.provider_configs SET enabled=false,last_connection_test_status='DISABLED' \
                 WHERE id=$1",
            )
            .bind(id)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "disableUser" => {
            let changed = sqlx::query("UPDATE ops.users SET status='DISABLED' WHERE id=$1")
                .bind(id)
                .execute(&mut **tx)
                .await
                .map_err(db)?
                .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
            sqlx::query(
                "UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) \
                 WHERE user_id=$1 AND revoked_at IS NULL",
            )
            .bind(id)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "grantRole" => {
            let user = uuid_value(payload, &["userId"]).ok_or(ServiceError::InvalidRequest)?;
            let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
            let role_exists: bool =
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM ops.roles WHERE id=$1)")
                    .bind(role)
                    .fetch_one(&mut **tx)
                    .await
                    .map_err(db)?;
            if !role_exists {
                return Err(ServiceError::NotFound);
            }
            sqlx::query(
                "INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason,expires_at) \
                 VALUES($1,$2,$3,$4,$5)",
            )
            .bind(user)
            .bind(role)
            .bind(actor)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(timestamp_value(payload, "expiresAt")?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "inviteUser" => {
            let email = string_value(payload, "email").ok_or(ServiceError::InvalidRequest)?;
            let display =
                string_value(payload, "displayName").ok_or(ServiceError::InvalidRequest)?;
            let oidc_subject = format!("invited:{}", sha256(email.to_ascii_lowercase().as_bytes()));
            sqlx::query(
                "INSERT INTO ops.users(id,oidc_subject,email,display_name,status) \
                 VALUES($1,$2,$3,$4,'INVITED')",
            )
            .bind(id)
            .bind(oidc_subject)
            .bind(email)
            .bind(display)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            for role in uuid_array(payload, "roleIds")? {
                let exists: bool =
                    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM ops.roles WHERE id=$1)")
                        .bind(role)
                        .fetch_one(&mut **tx)
                        .await
                        .map_err(db)?;
                if !exists {
                    return Err(ServiceError::NotFound);
                }
                sqlx::query(
                    "INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason,expires_at) \
                     VALUES($1,$2,$3,'initial invitation grant',$4)",
                )
                .bind(id)
                .bind(role)
                .bind(actor)
                .bind(timestamp_value(payload, "expiresAt")?)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
            }
        }
        "linkEvidence" => {
            let evidence =
                uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
            let target = uuid_value(payload, &["targetId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.evidence_links(evidence_id,target_type,target_id,relation, \
                 reason,created_by) VALUES($1,$2,$3,$4,$5,$6)",
            )
            .bind(evidence)
            .bind(string_value(payload, "targetType").ok_or(ServiceError::InvalidRequest)?)
            .bind(target)
            .bind(string_value(payload, "relation").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "linkSignalToCase" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.case_signals(case_id,signal_id,link_reason,linked_by) \
                 VALUES($1,$2,$3,$4) ON CONFLICT(case_id,signal_id) DO NOTHING",
            )
            .bind(case_id)
            .bind(signal)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            sqlx::query("UPDATE core.anomaly_signals SET status='LINKED' WHERE id=$1")
                .bind(signal)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
        }
        "pauseBackfill" => {
            let run =
                uuid_value(payload, &["backfillRunId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE ops.source_runs SET status='PAUSED',request_reason=$2 \
                 WHERE id=$1 AND mode IN ('BACKFILL','DRY_RUN') AND status='RUNNING'",
            )
            .bind(run)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::VersionConflict);
            }
        }
        "pauseJobQueue" => {
            let state = match string_value(payload, "mode") {
                Some("PAUSE_NEW") => "PAUSED_NEW",
                Some("PAUSE_AND_DRAIN") => "DRAINING",
                _ => return Err(ServiceError::InvalidRequest),
            };
            let queue = string_value(payload, "queueName").ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE ops.queue_controls SET state=$2,reason=$3,changed_by=$4, \
                 changed_at=clock_timestamp() WHERE queue_name=$1",
            )
            .bind(queue)
            .bind(state)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "pauseSource" => {
            let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
            let changed =
                sqlx::query("UPDATE ops.source_registry SET enabled=false WHERE source_id=$1")
                    .bind(source)
                    .execute(&mut **tx)
                    .await
                    .map_err(db)?
                    .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "placeTemporaryRestriction" => {
            let publication =
                uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
            let expires =
                timestamp_value(payload, "expiresAt")?.ok_or(ServiceError::InvalidRequest)?;
            if expires <= OffsetDateTime::now_utc() {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "INSERT INTO editorial.publication_access_decisions(id,publication_revision_id, \
                 scope,affected_ids,state,reason,expires_at,placed_by) \
                 VALUES($1,$2,$3,$4,'ACTIVE',$5,$6,$7)",
            )
            .bind(id)
            .bind(publication)
            .bind(string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?)
            .bind(
                payload
                    .get("affectedIds")
                    .cloned()
                    .unwrap_or_else(|| json!([])),
            )
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(expires)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "previewPublication" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let snapshot =
                uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
            let public_payload = publication_payload(case_id, snapshot, tx).await?;
            let digest = sha256(
                &serde_json::to_vec(&public_payload).map_err(|_| ServiceError::Persistence)?,
            );
            sqlx::query(
                "INSERT INTO editorial.publication_previews(id,case_id,review_snapshot_id,locale, \
                 preview_payload,preview_sha256,expires_at,created_by) \
                 VALUES($1,$2,$3,$4,$5,$6,clock_timestamp()+interval '15 minutes',$7)",
            )
            .bind(id)
            .bind(case_id)
            .bind(snapshot)
            .bind(string_value(payload, "locale").ok_or(ServiceError::InvalidRequest)?)
            .bind(public_payload)
            .bind(digest)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "publishCase" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let snapshot =
                uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
            let preview_hash = string_value(payload, "previewHash")
                .filter(|value| value.len() == 64)
                .ok_or(ServiceError::InvalidRequest)?;
            let snapshot_row = sqlx::query(
                "SELECT s.created_by,s.unresolved_blockers,c.current_review_snapshot_id, \
                 c.legal_review_required,EXISTS(SELECT 1 FROM ops.kill_switches \
                   WHERE state='ACTIVE' AND (expires_at IS NULL OR expires_at>clock_timestamp())) kill_switch \
                 FROM editorial.review_snapshots s JOIN editorial.cases c ON c.id=s.case_id \
                 WHERE s.id=$1 AND s.case_id=$2",
            )
            .bind(snapshot)
            .bind(case_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?;
            let snapshot_creator: Uuid = snapshot_row.try_get("created_by").map_err(db)?;
            let unresolved: Value = snapshot_row.try_get("unresolved_blockers").map_err(db)?;
            let current: Option<Uuid> = snapshot_row
                .try_get("current_review_snapshot_id")
                .map_err(db)?;
            let legal_required: bool = snapshot_row.try_get("legal_review_required").map_err(db)?;
            let kill_switch: bool = snapshot_row.try_get("kill_switch").map_err(db)?;
            if current != Some(snapshot)
                || !unresolved.as_array().is_some_and(Vec::is_empty)
                || kill_switch
            {
                return Err(ServiceError::InvalidRequest);
            }
            let approval: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM editorial.review_decisions \
                 WHERE review_snapshot_id=$1 AND decision='APPROVE' AND reviewer_id<>$2) \
                 AND (NOT $3 OR EXISTS(SELECT 1 FROM editorial.review_decisions d \
                   JOIN ops.user_roles ur ON ur.user_id=d.reviewer_id AND ur.revoked_at IS NULL \
                   JOIN ops.roles r ON r.id=ur.role_id AND r.code='LEGAL_REVIEWER' \
                   WHERE d.review_snapshot_id=$1 AND d.decision='APPROVE'))",
            )
            .bind(snapshot)
            .bind(snapshot_creator)
            .bind(legal_required)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if !approval {
                return Err(ServiceError::InvalidRequest);
            }
            let preview: Value = sqlx::query_scalar(
                "SELECT preview_payload FROM editorial.publication_previews \
                 WHERE case_id=$1 AND review_snapshot_id=$2 AND preview_sha256=$3 \
                   AND expires_at>clock_timestamp() ORDER BY created_at DESC LIMIT 1",
            )
            .bind(case_id)
            .bind(snapshot)
            .bind(preview_hash)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::InvalidRequest)?;
            let digest =
                sha256(&serde_json::to_vec(&preview).map_err(|_| ServiceError::Persistence)?);
            if digest != preview_hash {
                return Err(ServiceError::InvalidRequest);
            }
            let row = sqlx::query(
                "SELECT c.publication_state::text publication_state, \
                 GREATEST(COALESCE(c.current_publication_revision,0), \
                   COALESCE((SELECT max(r.revision) FROM editorial.publication_revisions r \
                             WHERE r.case_id=c.id),0))+1 revision, \
                 NULLIF(GREATEST(COALESCE(c.current_publication_revision,0), \
                   COALESCE((SELECT max(r.revision) FROM editorial.publication_revisions r \
                             WHERE r.case_id=c.id),0)),0) current_publication_revision \
                 FROM editorial.cases c WHERE c.id=$1 FOR UPDATE OF c",
            )
            .bind(case_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            let revision: i32 = row.try_get("revision").map_err(db)?;
            let state: String = row.try_get("publication_state").map_err(db)?;
            let supersedes: Option<i32> =
                row.try_get("current_publication_revision").map_err(db)?;
            sqlx::query(
                "INSERT INTO editorial.publication_revisions(case_id,revision,state,review_snapshot_id, \
                 public_payload,public_payload_sha256,preview_sha256,published_by,supersedes_revision,reason) \
                 VALUES($1,$2,$3::editorial.publication_state,$4,$5,$6,$7,$8,$9,$10)",
            )
            .bind(case_id)
            .bind(revision)
            .bind(&state)
            .bind(snapshot)
            .bind(preview)
            .bind(&digest)
            .bind(preview_hash)
            .bind(actor)
            .bind(supersedes)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            sqlx::query(
                "UPDATE editorial.cases SET current_review_snapshot_id=$2, \
                 current_publication_revision=$3 WHERE id=$1",
            )
            .bind(case_id)
            .bind(snapshot)
            .bind(revision)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "reassignTask" => {
            let assignee =
                uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE ops.tasks SET assignee_user_id=$2,assigned_by=$3, \
                 assignment_reason='reassigned by control command' WHERE id=$1",
            )
            .bind(id)
            .bind(assignee)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "proposeRoleDefinitionChange" => {
            let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO ops.role_change_proposals(id,role_id,add_capabilities, \
                 remove_capabilities,reason,status,proposed_by) \
                 VALUES($1,$2,$3,$4,$5,'REVIEW',$6)",
            )
            .bind(id)
            .bind(role)
            .bind(
                payload
                    .get("addCapabilities")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(
                payload
                    .get("removeCapabilities")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "revokeRole" => {
            let user = uuid_value(payload, &["userId"]).ok_or(ServiceError::InvalidRequest)?;
            let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE ops.user_roles SET revoked_at=clock_timestamp(),revoked_by=$3,version=version+1 \
                 WHERE user_id=$1 AND role_id=$2 AND revoked_at IS NULL",
            )
            .bind(user)
            .bind(role)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "retryJob" => {
            let job = uuid_value(payload, &["jobId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE ops.jobs SET status='QUEUED',run_after=clock_timestamp(),lease_owner=NULL, \
                 lease_token=NULL,lease_expires_at=NULL,last_error_code=NULL,last_error_detail=$2, \
                 completed_at=NULL WHERE id=$1 AND status IN ('FAILED','DEAD_LETTER')",
            )
            .bind(job)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::VersionConflict);
            }
        }
        "retryJobs" => {
            let max_count = payload
                .get("maxCount")
                .and_then(Value::as_i64)
                .filter(|value| (1..=1000).contains(value))
                .ok_or(ServiceError::InvalidRequest)?;
            let selected = if payload.contains_key("jobIds") {
                uuid_array(payload, "jobIds")?
            } else if let Some(snapshot) = uuid_value(payload, &["querySnapshotId"]) {
                sqlx::query_scalar::<_, Vec<Uuid>>(
                    "SELECT selected_job_ids FROM ops.job_query_snapshots \
                     WHERE id=$1 AND actor_user_id=$2 AND expires_at>clock_timestamp()",
                )
                .bind(snapshot)
                .bind(actor)
                .fetch_optional(&mut **tx)
                .await
                .map_err(db)?
                .ok_or(ServiceError::NotFound)?
            } else {
                return Err(ServiceError::InvalidRequest);
            };
            if selected.is_empty() || selected.len() as i64 > max_count {
                return Err(ServiceError::InvalidRequest);
            }
            let rows = sqlx::query(
                "UPDATE ops.jobs SET status='QUEUED',run_after=clock_timestamp(),lease_owner=NULL, \
                 lease_token=NULL,lease_expires_at=NULL,last_error_code=NULL,last_error_detail=$2, \
                 completed_at=NULL,version=version+1 \
                 WHERE id=ANY($1::uuid[]) AND status IN ('FAILED','DEAD_LETTER')",
            )
            .bind(&selected)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if rows != selected.len() as u64 {
                return Err(ServiceError::VersionConflict);
            }
        }
        "retrySourceRun" => {
            let source_run =
                uuid_value(payload, &["sourceRunId"]).ok_or(ServiceError::InvalidRequest)?;
            let row = sqlx::query(
                "SELECT source_id,mode,checkpoint_before FROM ops.source_runs \
                 WHERE id=$1 AND status IN ('FAILED','CANCELLED')",
            )
            .bind(source_run)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::VersionConflict)?;
            sqlx::query(
                "INSERT INTO ops.source_runs(id,source_id,mode,checkpoint_before,status, \
                 retry_of_source_run_id,request_reason,requested_by) \
                 VALUES($1,$2,$3,$4,'QUEUED',$5,$6,$7)",
            )
            .bind(Uuid::new_v4())
            .bind(row.try_get::<String, _>("source_id").map_err(db)?)
            .bind(row.try_get::<String, _>("mode").map_err(db)?)
            .bind(
                row.try_get::<Option<Value>, _>("checkpoint_before")
                    .map_err(db)?,
            )
            .bind(source_run)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "rollbackRuleVersion" => {
            let current =
                uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
            let target =
                uuid_value(payload, &["targetVersionId"]).ok_or(ServiceError::InvalidRequest)?;
            let same_rule: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM core.rule_versions target \
                 JOIN core.rule_versions current ON current.id=$1 \
                 WHERE target.id=$2 AND target.rule_id=current.rule_id \
                   AND target.status IN ('RETIRED','ROLLED_BACK','ACTIVE'))",
            )
            .bind(current)
            .bind(target)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if !same_rule {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "UPDATE core.rule_versions SET status='ROLLED_BACK',retired_at=clock_timestamp(), \
                 activation_reason=$2 WHERE id=$1",
            )
            .bind(current)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            sqlx::query(
                "UPDATE core.rule_versions SET status='ACTIVE',effective_at=clock_timestamp(), \
                 retired_at=NULL WHERE id=$1",
            )
            .bind(target)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "runRuleEvaluation" => {
            let rule =
                uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
            let dataset =
                uuid_value(payload, &["datasetSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id, \
                 evaluation_profile,status,requested_by,reason) \
                 VALUES($1,$2,$3,$4,'QUEUED',$5,$6)",
            )
            .bind(id)
            .bind(rule)
            .bind(dataset)
            .bind(string_value(payload, "evaluationProfile").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            enqueue_runtime_job(
                tx,
                "RULE_EVALUATION",
                "analysis-worker",
                json!({"evaluationId":id}),
                format!("rule-evaluation:{id}"),
            )
            .await?;
        }
        "resolveCorrectionRequest" => {
            let correction =
                uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
            let resolution =
                string_value(payload, "resolution").ok_or(ServiceError::InvalidRequest)?;
            if !matches!(
                resolution,
                "RESOLVED" | "REJECTED" | "DUPLICATE" | "WITHDRAWN"
            ) {
                return Err(ServiceError::InvalidRequest);
            }
            let status = if resolution == "RESOLVED" {
                "PUBLISHED"
            } else {
                "REJECTED"
            };
            let changed = sqlx::query(
                "UPDATE editorial.corrections SET resolution=$2,resolution_reason=$3, \
                 resolved_at=clock_timestamp(),status=$4 WHERE id=$1 AND status='REVIEW'",
            )
            .bind(correction)
            .bind(resolution)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(status)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
            sqlx::query(
                "UPDATE ops.tasks SET status='DONE',completed_at=clock_timestamp() \
                 WHERE object_type='CORRECTION' AND object_id=$1 AND status<>'DONE'",
            )
            .bind(correction)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "saveResponseRequestDraft" => {
            let request =
                uuid_value(payload, &["responseRequestId"]).ok_or(ServiceError::InvalidRequest)?;
            let (email_hash, encrypted) =
                if let Some(raw) = payload.get("recipientEmail").and_then(Value::as_str) {
                    let email = normalized_email(raw)?;
                    (
                        Some(sha256(email.as_bytes())),
                        Some(encrypt_control_field(
                            field_keys,
                            "editorial.response_requests",
                            "recipient_email_encrypted",
                            request,
                            "email-address",
                            email.as_bytes(),
                        )?),
                    )
                } else {
                    (None, None)
                };
            let changed = sqlx::query(
                "UPDATE editorial.response_requests SET recipient_email_hash=COALESCE($2,recipient_email_hash), \
                 recipient_email_encrypted=COALESCE($3,recipient_email_encrypted), \
                 questions=COALESCE($4,questions),due_at=COALESCE($5,due_at), \
                 requested_publication_scope=COALESCE($6,requested_publication_scope) \
                 WHERE id=$1 AND status='DRAFT'",
            )
            .bind(request)
            .bind(email_hash)
            .bind(encrypted)
            .bind(payload.get("questions").cloned())
            .bind(timestamp_value(payload, "dueAt")?)
            .bind(payload.get("requestedPublicationScope").cloned())
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::VersionConflict);
            }
        }
        "startAccessReview" => {
            let reviewers = uuid_array(payload, "reviewerUserIds")?;
            if reviewers.is_empty() {
                return Err(ServiceError::InvalidRequest);
            }
            let scope = string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?;
            let scope_id = uuid_value(payload, &["scopeId"]);
            sqlx::query(
                "INSERT INTO ops.access_reviews(id,scope,scope_id,reviewer_user_ids,due_at,reason, \
                 status,created_by) VALUES($1,$2,$3,$4,$5,$6,'OPEN',$7)",
            )
            .bind(id)
            .bind(scope)
            .bind(scope_id)
            .bind(
                payload
                    .get("reviewerUserIds")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(timestamp_value(payload, "dueAt")?.ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            for reviewer in reviewers {
                sqlx::query(
                    "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority, \
                     assignee_user_id,due_at,assigned_by,assignment_reason) \
                     VALUES('ACCESS_REVIEW','ACCESS_REVIEW',$1,'Access review','OPEN','HIGH',$2,$3,$4,$5)",
                )
                .bind(id)
                .bind(reviewer)
                .bind(timestamp_value(payload, "dueAt")?)
                .bind(actor)
                .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
            }
        }
        "startAgentRun" => {
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
            let evidence_snapshot: Value = sqlx::query_scalar(
                "SELECT COALESCE(jsonb_agg(jsonb_build_object( \
                   'id',e.id,'contentSha256',btrim(e.content_sha256::text), \
                   'locator',e.source_locator,'updatedAt',e.updated_at, \
                   'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb) \
                 ) ORDER BY e.id),'[]'::jsonb) \
                 FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id \
                 WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) \
                   AND e.verification_status='VERIFIED'",
            )
            .bind(case_id)
            .bind(&evidence_ids)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if evidence_snapshot
                .as_array()
                .is_none_or(|rows| rows.len() != evidence_ids.len())
            {
                return Err(ServiceError::InvalidRequest);
            }
            let snapshot = json!({
                "caseId":case_id,
                "evidence":evidence_snapshot,
                "objective":string_value(payload,"objective").ok_or(ServiceError::InvalidRequest)?,
            });
            sqlx::query(
                "INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids, \
                 provider_policy,status,input_snapshot_hash,max_cost,created_by) \
                 VALUES($1,$2,$3,$4,$5,$6,'QUEUED',$7,$8,$9)",
            )
            .bind(id)
            .bind(case_id)
            .bind(string_value(payload, "agentType").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "objective").ok_or(ServiceError::InvalidRequest)?)
            .bind(evidence)
            .bind(string_value(payload, "providerPolicy").ok_or(ServiceError::InvalidRequest)?)
            .bind(sha256(
                &serde_json::to_vec(&snapshot).map_err(|_| ServiceError::Persistence)?,
            ))
            .bind(decimal_string(payload, "maxCost")?)
            .bind(actor)
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
        }
        "startBackfill" => {
            let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
            let from = date_value(payload, "from")?;
            let to = date_value(payload, "to")?;
            if from > to {
                return Err(ServiceError::InvalidRequest);
            }
            let mode = match string_value(payload, "mode") {
                Some("dry_run") => "DRY_RUN",
                Some("execute") => "BACKFILL",
                _ => return Err(ServiceError::InvalidRequest),
            };
            let allowed: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM ops.source_registry \
                 WHERE source_id=$1 AND enabled AND legal_status='APPROVED')",
            )
            .bind(source)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if !allowed {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "INSERT INTO ops.source_runs(id,source_id,mode,status,requested_from,requested_to, \
                 request_reason,requested_by) VALUES($1,$2,$3,'QUEUED',$4,$5,$6,$7)",
            )
            .bind(id)
            .bind(source)
            .bind(mode)
            .bind(from)
            .bind(to)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            enqueue_runtime_job(
                tx,
                "SOURCE_RUN",
                "ingest-worker",
                json!({"sourceRunId":id}),
                format!("source-run:{id}"),
            )
            .await?;
        }
        "startRuleShadow" => {
            let rule =
                uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
            let dataset =
                uuid_value(payload, &["datasetSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE core.rule_versions SET status='SHADOW',activation_reason=$2 \
                 WHERE id=$1 AND status='DRAFT'",
            )
            .bind(rule)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::VersionConflict);
            }
            let evaluation_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id, \
                 evaluation_profile,status,requested_by,reason) \
                 VALUES($1,$2,$3,'SHADOW','QUEUED',$4,$5)",
            )
            .bind(evaluation_id)
            .bind(rule)
            .bind(dataset)
            .bind(actor)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            enqueue_runtime_job(
                tx,
                "RULE_EVALUATION",
                "analysis-worker",
                json!({"evaluationId":evaluation_id}),
                format!("rule-evaluation:{evaluation_id}"),
            )
            .await?;
        }
        "startSourceRun" => {
            let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
            let mode = match string_value(payload, "mode") {
                Some("incremental") => "INCREMENTAL",
                Some("reconcile") => "RECONCILE",
                Some("full") => "FULL",
                _ => return Err(ServiceError::InvalidRequest),
            };
            let allowed: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM ops.source_registry \
                 WHERE source_id=$1 AND enabled AND legal_status='APPROVED')",
            )
            .bind(source)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if !allowed {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "INSERT INTO ops.source_runs(id,source_id,mode,status,request_reason,requested_by) \
                 VALUES($1,$2,$3,'QUEUED',$4,$5)",
            )
            .bind(id)
            .bind(source)
            .bind(mode)
            .bind(payload.get("reason").and_then(Value::as_str))
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            enqueue_runtime_job(
                tx,
                "SOURCE_RUN",
                "ingest-worker",
                json!({"sourceRunId":id}),
                format!("source-run:{id}"),
            )
            .await?;
        }
        "submitReview" => {
            let snapshot =
                uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
            let decision = match string_value(payload, "decision") {
                Some("approve") | Some("APPROVE") => "APPROVE",
                Some("reject") | Some("REJECT") => "REJECT",
                Some("changes_required") | Some("CHANGES_REQUIRED") => "CHANGES_REQUIRED",
                _ => return Err(ServiceError::InvalidRequest),
            };
            let row = sqlx::query(
                "SELECT a.id,s.created_by snapshot_created_by \
                 FROM editorial.review_assignments a \
                 JOIN editorial.review_snapshots s ON s.id=$1 AND s.case_id=a.case_id \
                 WHERE a.reviewer_id=$2 AND a.status IN ('ASSIGNED','IN_PROGRESS') \
                   AND (a.review_snapshot_id IS NULL OR a.review_snapshot_id=$1) \
                 ORDER BY a.created_at DESC LIMIT 1 FOR UPDATE OF a",
            )
            .bind(snapshot)
            .bind(actor)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?;
            let creator: Uuid = row.try_get("snapshot_created_by").map_err(db)?;
            if creator == actor {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision, \
                 reason,criteria,reviewer_independence,reauth_context_hash) \
                 VALUES($1,$2,$3::editorial.review_decision,$4,$5,$6,$7)",
            )
            .bind(snapshot)
            .bind(actor)
            .bind(decision)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(
                payload
                    .get("criteria")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            )
            .bind(json!({"snapshotCreatedBy":creator,"reviewer":actor,"independent":true}))
            .bind(sha256(format!("review:{snapshot}:{actor}").as_bytes()))
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            let assignment: Uuid = row.try_get("id").map_err(db)?;
            sqlx::query(
                "UPDATE editorial.review_assignments SET status='COMPLETED',completed_at=clock_timestamp(), \
                 version=version+1 WHERE id=$1",
            )
            .bind(assignment)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            sqlx::query(
                "UPDATE ops.tasks SET status='DONE',completed_at=clock_timestamp() \
                 WHERE task_type='REVIEW' AND object_id IN ($1,(SELECT case_id FROM editorial.review_snapshots WHERE id=$1)) \
                   AND assignee_user_id=$2 AND status<>'DONE'",
            )
            .bind(snapshot)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "testProviderConnection" => {
            let provider =
                uuid_value(payload, &["providerId"]).ok_or(ServiceError::InvalidRequest)?;
            let enabled: bool =
                sqlx::query_scalar("SELECT enabled FROM ops.provider_configs WHERE id=$1")
                    .bind(provider)
                    .fetch_optional(&mut **tx)
                    .await
                    .map_err(db)?
                    .ok_or(ServiceError::NotFound)?;
            if !enabled {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "INSERT INTO ops.provider_connection_tests(id,provider_id,test_model,status, \
                 requested_by,reason) VALUES($1,$2,$3,'QUEUED',$4,$5)",
            )
            .bind(id)
            .bind(provider)
            .bind(string_value(payload, "testModel").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .bind(payload.get("reason").and_then(Value::as_str))
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            enqueue_runtime_job(
                tx,
                "PROVIDER_CONNECTION_TEST",
                "analysis-worker",
                json!({"providerConnectionTestId":id}),
                format!("provider-connection-test:{id}"),
            )
            .await?;
        }
        "transitionCase" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let target =
                string_value(payload, "targetState").ok_or(ServiceError::InvalidRequest)?;
            let current: String = sqlx::query_scalar(
                "SELECT investigation_state::text FROM editorial.cases WHERE id=$1",
            )
            .bind(case_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            if !valid_case_transition(&current, target) {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "UPDATE editorial.cases SET investigation_state=$2::editorial.investigation_state \
                 WHERE id=$1",
            )
            .bind(case_id)
            .bind(target)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "triageCorrection" => {
            let correction =
                uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
            let decision = string_value(payload, "decision").ok_or(ServiceError::InvalidRequest)?;
            let status = match decision {
                "ACCEPT" => "REVIEW",
                "NEEDS_INFORMATION" => "DRAFT",
                "REJECT" | "DUPLICATE" => "REJECTED",
                _ => return Err(ServiceError::InvalidRequest),
            };
            let priority = string_value(payload, "priority").ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE editorial.corrections SET triage_decision=$2,priority=$3, \
                 triage_reason=$4,status=$5 WHERE id=$1",
            )
            .bind(correction)
            .bind(decision)
            .bind(priority)
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(status)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
            upsert_task(
                tx,
                "CORRECTION",
                correction,
                "Correction review",
                if status == "REJECTED" { "DONE" } else { "OPEN" },
                priority,
                None,
                actor,
                Some(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?),
            )
            .await?;
        }
        "triageSignal" => {
            let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
            let status = match string_value(payload, "decision") {
                Some("investigate") => "ASSIGNED",
                Some("dismiss") => "DISMISSED",
                Some("duplicate") => "DUPLICATE",
                Some("needs_data") => "NEEDS_DATA",
                _ => return Err(ServiceError::InvalidRequest),
            };
            sqlx::query(
                "UPDATE core.anomaly_signals SET status=$2::core.signal_status WHERE id=$1",
            )
            .bind(signal)
            .bind(status)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            upsert_task(
                tx,
                "SIGNAL",
                signal,
                "Signal triage",
                if matches!(status, "DISMISSED" | "DUPLICATE") {
                    "DONE"
                } else {
                    "OPEN"
                },
                "HIGH",
                None,
                actor,
                Some(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?),
            )
            .await?;
        }
        "unlinkSignalFromCase" => {
            let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
            let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed =
                sqlx::query("DELETE FROM editorial.case_signals WHERE case_id=$1 AND signal_id=$2")
                    .bind(case_id)
                    .bind(signal)
                    .execute(&mut **tx)
                    .await
                    .map_err(db)?
                    .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
            sqlx::query(
                "UPDATE core.anomaly_signals SET status= \
                 CASE WHEN assigned_user_id IS NULL THEN 'NEW'::core.signal_status \
                      ELSE 'ASSIGNED'::core.signal_status END WHERE id=$1",
            )
            .bind(signal)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "updateBudgetLimit" => {
            let scope = string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?;
            let daily = decimal_string(payload, "dailyLimit")?;
            let monthly = decimal_string(payload, "monthlyLimit")?;
            if daily < rust_decimal::Decimal::ZERO || monthly < daily {
                return Err(ServiceError::InvalidRequest);
            }
            let changed = sqlx::query(
                "UPDATE ops.budget_limits SET daily_limit=$2,monthly_limit=$3,currency=$4, \
                 updated_by=$5,updated_at=clock_timestamp() WHERE scope=$1",
            )
            .bind(scope)
            .bind(daily)
            .bind(monthly)
            .bind(string_value(payload, "currency").ok_or(ServiceError::InvalidRequest)?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "updateClaim" => {
            let claim = uuid_value(payload, &["claimId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE editorial.claims SET text=COALESCE($2,text),limitations=COALESCE($3,limitations) \
                 WHERE id=$1",
            )
            .bind(claim)
            .bind(payload.get("text").and_then(Value::as_str))
            .bind(payload.get("limitations").cloned())
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
            if payload.contains_key("evidenceIds") || payload.contains_key("responseIds") {
                replace_claim_relations(claim, payload, tx).await?;
            }
        }
        "updateCorrectionDraft" => {
            let correction =
                uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE editorial.corrections SET summary=COALESCE($2,summary),reason=COALESCE($3,reason), \
                 affected_claim_ids=COALESCE($4,affected_claim_ids), \
                 replacement_content=COALESCE($5,replacement_content) \
                 WHERE id=$1 AND status='DRAFT'",
            )
            .bind(correction)
            .bind(payload.get("summary").and_then(Value::as_str))
            .bind(payload.get("reason").and_then(Value::as_str))
            .bind(payload.get("affectedClaimIds").cloned())
            .bind(payload.get("replacementContent").cloned())
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "updateEvidence" => {
            let evidence =
                uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE editorial.evidence SET title=COALESCE($2,title), \
                 source_locator=COALESCE($3,source_locator), \
                 classification=COALESCE($4::editorial.evidence_classification,classification), \
                 description=COALESCE($5,description) WHERE id=$1",
            )
            .bind(evidence)
            .bind(payload.get("title").and_then(Value::as_str))
            .bind(payload.get("locator").and_then(Value::as_str))
            .bind(payload.get("classification").and_then(Value::as_str))
            .bind(payload.get("notes").and_then(Value::as_str))
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "updateHypothesis" => {
            let hypothesis =
                uuid_value(payload, &["hypothesisId"]).ok_or(ServiceError::InvalidRequest)?;
            let changed = sqlx::query(
                "UPDATE editorial.hypotheses SET statement=COALESCE($2,statement), \
                 status=COALESCE($3,status),unknowns=COALESCE($4,unknowns) WHERE id=$1",
            )
            .bind(hypothesis)
            .bind(payload.get("statement").and_then(Value::as_str))
            .bind(payload.get("status").and_then(Value::as_str))
            .bind(payload.get("unknowns").cloned())
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
            if payload.contains_key("supportingEvidenceIds")
                || payload.contains_key("contradictingEvidenceIds")
            {
                replace_hypothesis_relations(hypothesis, payload, actor, tx).await?;
            }
        }
        "validateClaims" => {
            let claim = uuid_value(payload, &["claimId"]).ok_or(ServiceError::InvalidRequest)?;
            let blockers: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM editorial.claim_evidence ce \
                 JOIN editorial.evidence e ON e.id=ce.evidence_id \
                 WHERE ce.claim_id=$1 AND e.verification_status<>'VERIFIED'",
            )
            .bind(claim)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
            let status = if blockers == 0 { "VALID" } else { "BLOCKED" };
            let changed = sqlx::query("UPDATE editorial.claims SET validation_status=$2::core.claim_validation_status WHERE id=$1")
                .bind(claim).bind(status).execute(&mut **tx).await.map_err(db)?.rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "verifyAuditIntegrity" => {
            let mode = string_value(payload, "mode").ok_or(ServiceError::InvalidRequest)?;
            let from = uuid_value(payload, &["fromEventId"]);
            let to = uuid_value(payload, &["toEventId"]);
            let expected = payload.get("expectedChainHead").and_then(Value::as_str);
            match mode {
                "FULL" | "TAIL" if from.is_none() && to.is_none() => {}
                "RANGE" if from.is_some() && to.is_some() => {}
                _ => return Err(ServiceError::InvalidRequest),
            }
            if expected.is_some_and(|value| !is_sha256(value)) {
                return Err(ServiceError::InvalidRequest);
            }
            sqlx::query(
                "INSERT INTO ops.audit_verification_runs(id,mode,from_event_id,to_event_id, \
                 expected_chain_head,status,requested_by) VALUES($1,$2,$3,$4,$5,'QUEUED',$6)",
            )
            .bind(id)
            .bind(mode)
            .bind(from)
            .bind(to)
            .bind(expected)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "verifyEvidence" => {
            let evidence =
                uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
            let requested =
                string_value(payload, "verificationStatus").ok_or(ServiceError::InvalidRequest)?;
            let status = match requested {
                "verified" | "VERIFIED" => "VERIFIED",
                "rejected" | "REJECTED" => "REJECTED",
                "needs_work" | "NEEDS_WORK" => "NEEDS_WORK",
                _ => return Err(ServiceError::InvalidRequest),
            };
            let changed = sqlx::query(
                "UPDATE editorial.evidence SET verification_status=$2,verified_by=$3, \
                 verified_at=CASE WHEN $2='VERIFIED' THEN clock_timestamp() ELSE NULL END WHERE id=$1",
            )
            .bind(evidence)
            .bind(status)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "createAuditExport" => {
            let seconds = payload
                .get("expiresInSeconds")
                .and_then(Value::as_i64)
                .filter(|value| (300..=86_400).contains(value))
                .ok_or(ServiceError::InvalidRequest)?;
            let expires_at = OffsetDateTime::now_utc()
                .checked_add(time::Duration::seconds(seconds))
                .ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO ops.audit_exports(id,requested_by,from_at,to_at,format,scope,object_type,object_id,reason,watermark_policy,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            )
            .bind(id)
            .bind(actor)
            .bind(timestamp_value(payload, "from")?.ok_or(ServiceError::InvalidRequest)?)
            .bind(timestamp_value(payload, "to")?.ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "format").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?)
            .bind(payload.get("objectType").and_then(Value::as_str))
            .bind(payload.get("objectId").and_then(Value::as_str))
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "watermarkPolicy").ok_or(ServiceError::InvalidRequest)?)
            .bind(expires_at)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
            sqlx::query(
                "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key) VALUES('AUDIT_EXPORT','audit-export',$1,$2)",
            )
            .bind(json!({"auditExportId":id}))
            .bind(format!("audit-export:{id}"))
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "placeLegalHold" => {
            sqlx::query(
                "INSERT INTO editorial.legal_holds(id,case_id,review_snapshot_id,object_type,object_id,scope,affected_ids,reason,authority_reference,expires_at,placed_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            )
            .bind(id)
            .bind(uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?)
            .bind(uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "objectType").ok_or(ServiceError::InvalidRequest)?)
            .bind(uuid_value(payload, &["objectId"]).ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?)
            .bind(payload.get("affectedIds").cloned().unwrap_or_else(|| json!([])))
            .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
            .bind(string_value(payload, "authorityReference").ok_or(ServiceError::InvalidRequest)?)
            .bind(timestamp_value(payload, "expiresAt")?)
            .bind(actor)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
        "activateKillSwitch" => {
            let changed = sqlx::query("UPDATE ops.kill_switches SET scope=$2,state='ACTIVE',reason=$3,activated_by=$4,activated_at=clock_timestamp(),expires_at=$5,deactivated_by=NULL,deactivated_at=NULL,updated_at=clock_timestamp() WHERE id=$1")
                .bind(id).bind(payload.get("scope").cloned().ok_or(ServiceError::InvalidRequest)?)
                .bind(string_value(payload,"reason").ok_or(ServiceError::InvalidRequest)?)
                .bind(actor).bind(timestamp_value(payload,"expiresAt")?)
                .execute(&mut **tx).await.map_err(db)?.rows_affected();
            if changed != 1 {
                return Err(ServiceError::NotFound);
            }
        }
        "deactivateKillSwitch" => {
            if let Some(target) = uuid_value(payload, &["killSwitchId", "id"]) {
                let changed=sqlx::query("UPDATE ops.kill_switches SET state='INACTIVE',deactivated_by=$2,deactivated_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=$1 AND state='ACTIVE'").bind(target).bind(actor).execute(&mut **tx).await.map_err(db)?.rows_affected();
                if changed == 0 {
                    return Err(ServiceError::NotFound);
                }
            }
        }
        "extendKillSwitch" => {
            if let Some(target) = uuid_value(payload, &["killSwitchId", "id"]) {
                let changed=sqlx::query("UPDATE ops.kill_switches SET expires_at=$2,updated_at=clock_timestamp() WHERE id=$1 AND state='ACTIVE'").bind(target).bind(timestamp_value(payload,"expiresAt")?).execute(&mut **tx).await.map_err(db)?.rows_affected();
                if changed == 0 {
                    return Err(ServiceError::NotFound);
                }
            }
        }
        "markNotificationRead" => {
            if let Some(target) = uuid_value(payload, &["notificationId", "id"]) {
                sqlx::query("UPDATE ops.notifications SET read_at=COALESCE(read_at,clock_timestamp()) WHERE id=$1").bind(target).execute(&mut **tx).await.map_err(db)?;
            }
        }
        "revokeOwnSession" => {
            sqlx::query("UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE user_id=$1 AND revoked_at IS NULL").bind(actor).execute(&mut **tx).await.map_err(db)?;
        }
        "revokeUserSessions" => {
            if let Some(user) = uuid_value(payload, &["userId"]) {
                sqlx::query("UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE user_id=$1 AND revoked_at IS NULL").bind(user).execute(&mut **tx).await.map_err(db)?;
            }
        }
        "cancelJob" | "quarantineJob" => {
            if let Some(job) = uuid_value(payload, &["jobId", "id"]) {
                let status = if operation == "cancelJob" {
                    "CANCELLED"
                } else {
                    "QUARANTINED"
                };
                sqlx::query("UPDATE ops.jobs SET status=$2::ops.job_status,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,run_after=CASE WHEN $2='QUEUED' THEN clock_timestamp() ELSE run_after END WHERE id=$1").bind(job).bind(status).execute(&mut **tx).await.map_err(db)?;
            }
        }
        _ => {}
    }
    Ok(())
}

async fn replace_claim_relations(
    claim: Uuid,
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(values) = payload.get("evidenceIds") {
        sqlx::query("DELETE FROM editorial.claim_evidence WHERE claim_id=$1")
            .bind(claim)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        let ids = values
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
        for (index, evidence) in ids.into_iter().enumerate() {
            sqlx::query(
                "INSERT INTO editorial.claim_evidence(claim_id,evidence_id,citation_label, \
                 citation_order,supports) VALUES($1,$2,$3,$4,'FACT')",
            )
            .bind(claim)
            .bind(evidence)
            .bind(format!("E{}", index + 1))
            .bind(i32::try_from(index + 1).map_err(|_| ServiceError::InvalidRequest)?)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
    }
    if let Some(values) = payload.get("responseIds") {
        sqlx::query("DELETE FROM editorial.claim_responses WHERE claim_id=$1")
            .bind(claim)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        let ids = values.as_array().ok_or(ServiceError::InvalidRequest)?;
        for response in ids {
            let response = response
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ServiceError::InvalidRequest)?;
            sqlx::query(
                "INSERT INTO editorial.claim_responses(claim_id,response_id,relation) \
                 VALUES($1,$2,'RESPONDS')",
            )
            .bind(claim)
            .bind(response)
            .execute(&mut **tx)
            .await
            .map_err(db)?;
        }
    }
    Ok(())
}

async fn enqueue_runtime_job(
    tx: &mut Transaction<'_, Postgres>,
    job_type: &str,
    queue: &str,
    payload: Value,
    dedupe_key: String,
) -> Result<(), ServiceError> {
    sqlx::query(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
         VALUES($1,$2,$3,$4,8)",
    )
    .bind(job_type)
    .bind(queue)
    .bind(payload)
    .bind(dedupe_key)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn upsert_task(
    tx: &mut Transaction<'_, Postgres>,
    task_type: &str,
    object_id: Uuid,
    title: &str,
    status: &str,
    priority: &str,
    assignee: Option<Uuid>,
    actor: Uuid,
    reason: Option<&str>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query(
        "UPDATE ops.tasks SET title=$3,status=$4,priority=$5, \
         assignee_user_id=COALESCE($6,assignee_user_id),assigned_by=$7, \
         assignment_reason=COALESCE($8,assignment_reason), \
         completed_at=CASE WHEN $4='DONE' THEN clock_timestamp() ELSE NULL END \
         WHERE task_type=$1 AND object_type=$1 AND object_id=$2 AND status<>'CANCELLED'",
    )
    .bind(task_type)
    .bind(object_id)
    .bind(title)
    .bind(status)
    .bind(priority)
    .bind(assignee)
    .bind(actor)
    .bind(reason)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed == 0 {
        sqlx::query(
            "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority, \
             assignee_user_id,assigned_by,assignment_reason,completed_at) \
             VALUES($1,$1,$2,$3,$4,$5,$6,$7,$8, \
             CASE WHEN $4='DONE' THEN clock_timestamp() ELSE NULL END)",
        )
        .bind(task_type)
        .bind(object_id)
        .bind(title)
        .bind(status)
        .bind(priority)
        .bind(assignee)
        .bind(actor)
        .bind(reason)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }
    Ok(())
}

async fn replace_hypothesis_relations(
    hypothesis: Uuid,
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if !payload.contains_key("supportingEvidenceIds")
        && !payload.contains_key("contradictingEvidenceIds")
    {
        return Ok(());
    }
    sqlx::query("DELETE FROM editorial.hypothesis_evidence WHERE hypothesis_id=$1")
        .bind(hypothesis)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    for (key, relation) in [
        ("supportingEvidenceIds", "SUPPORTS"),
        ("contradictingEvidenceIds", "CONTRADICTS"),
    ] {
        if let Some(values) = payload.get(key) {
            for evidence in values.as_array().ok_or(ServiceError::InvalidRequest)? {
                let evidence = evidence
                    .as_str()
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .ok_or(ServiceError::InvalidRequest)?;
                sqlx::query(
                    "INSERT INTO editorial.hypothesis_evidence(hypothesis_id,evidence_id,relation,added_by) \
                     VALUES($1,$2,$3,$4)",
                )
                .bind(hypothesis)
                .bind(evidence)
                .bind(relation)
                .bind(actor)
                .execute(&mut **tx)
                .await
                .map_err(db)?;
            }
        }
    }
    Ok(())
}

async fn publication_payload(
    case_id: Uuid,
    snapshot_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Value, ServiceError> {
    let row = sqlx::query(
        "SELECT c.public_slug,c.title,c.summary,s.snapshot_payload \
         FROM editorial.cases c JOIN editorial.review_snapshots s ON s.case_id=c.id \
         WHERE c.id=$1 AND s.id=$2",
    )
    .bind(case_id)
    .bind(snapshot_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let snapshot: Value = row.try_get("snapshot_payload").map_err(db)?;
    let snapshot = snapshot.as_object().ok_or(ServiceError::Persistence)?;
    let claim_ids = optional_uuid_array(snapshot, "claimIds")?;
    let evidence_ids = optional_uuid_array(snapshot, "evidenceIds")?;
    let response_ids = optional_uuid_array(snapshot, "responseIds")?;

    let claim_rows = sqlx::query(
        "SELECT c.id,c.claim_type::text claim_type,c.text,c.limitations, \
         COALESCE((SELECT jsonb_agg(ce.evidence_id ORDER BY ce.citation_order) \
                   FROM editorial.claim_evidence ce WHERE ce.claim_id=c.id),'[]'::jsonb) evidence_ids, \
         COALESCE((SELECT jsonb_agg(cr.response_id ORDER BY cr.response_id) \
                   FROM editorial.claim_responses cr WHERE cr.claim_id=c.id),'[]'::jsonb) response_ids \
         FROM editorial.claims c WHERE c.case_id=$1 AND c.id=ANY($2::uuid[]) \
         ORDER BY array_position($2::uuid[],c.id)",
    )
    .bind(case_id)
    .bind(&claim_ids)
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if claim_rows.len() != claim_ids.len() {
        return Err(ServiceError::InvalidRequest);
    }
    let mut claims = Vec::with_capacity(claim_rows.len());
    for claim in claim_rows {
        let limitations: Value = claim.try_get("limitations").map_err(db)?;
        if !limitations
            .as_array()
            .is_some_and(|items| items.iter().all(Value::is_string))
        {
            return Err(ServiceError::InvalidRequest);
        }
        claims.push(json!({
            "id":claim.try_get::<Uuid,_>("id").map_err(db)?,
            "claimType":claim.try_get::<String,_>("claim_type").map_err(db)?,
            "text":claim.try_get::<String,_>("text").map_err(db)?,
            "evidenceIds":claim.try_get::<Value,_>("evidence_ids").map_err(db)?,
            "responseIds":claim.try_get::<Value,_>("response_ids").map_err(db)?,
            "limitations":limitations,
        }));
    }

    let evidence_rows = sqlx::query(
        "SELECT e.id,e.title,e.evidence_type,e.source_url,e.source_locator,e.content_sha256, \
         e.redacted_public_excerpt,e.classification::text classification,e.verification_status \
         FROM editorial.evidence e WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) \
         ORDER BY array_position($2::uuid[],e.id)",
    )
    .bind(case_id)
    .bind(&evidence_ids)
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if evidence_rows.len() != evidence_ids.len() {
        return Err(ServiceError::InvalidRequest);
    }
    let mut evidence = Vec::with_capacity(evidence_rows.len());
    for item in evidence_rows {
        let classification: String = item.try_get("classification").map_err(db)?;
        let verification_status: String = item.try_get("verification_status").map_err(db)?;
        if classification != "PUBLIC" || verification_status != "VERIFIED" {
            return Err(ServiceError::InvalidRequest);
        }
        evidence.push(json!({
            "id":item.try_get::<Uuid,_>("id").map_err(db)?,
            "title":item.try_get::<String,_>("title").map_err(db)?,
            "evidenceType":item.try_get::<String,_>("evidence_type").map_err(db)?,
            "sourceUrl":item.try_get::<Option<String>,_>("source_url").map_err(db)?,
            "sourceLocator":item.try_get::<String,_>("source_locator").map_err(db)?,
            "contentSha256":item.try_get::<String,_>("content_sha256").map_err(db)?.trim(),
            "publicExcerpt":item.try_get::<Option<String>,_>("redacted_public_excerpt").map_err(db)?,
            "restriction":Value::Null,
        }));
    }

    let response_rows = sqlx::query(
        "SELECT r.id,r.party_name,r.submitted_at,r.public_excerpt,r.publication_consent, \
         r.editorial_status FROM editorial.responses r \
         WHERE r.case_id=$1 AND r.id=ANY($2::uuid[]) \
         ORDER BY array_position($2::uuid[],r.id)",
    )
    .bind(case_id)
    .bind(&response_ids)
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if response_rows.len() != response_ids.len() {
        return Err(ServiceError::InvalidRequest);
    }
    let mut responses = Vec::with_capacity(response_rows.len());
    for response in response_rows {
        let status: String = response.try_get("editorial_status").map_err(db)?;
        if !matches!(status.as_str(), "ACCEPTED" | "PARTIAL" | "PUBLISHED") {
            return Err(ServiceError::InvalidRequest);
        }
        responses.push(json!({
            "id":response.try_get::<Uuid,_>("id").map_err(db)?,
            "partyName":response.try_get::<String,_>("party_name").map_err(db)?,
            "status":status,
            "submittedAt":format_time(response.try_get("submitted_at").map_err(db)?)?,
            "excerpt":response.try_get::<Option<String>,_>("public_excerpt").map_err(db)?,
            "attachmentCount":0,
            "publicationConsent":response.try_get::<Value,_>("publication_consent").map_err(db)?,
        }));
    }

    let source_freshness = snapshot
        .get("sourceFreshness")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if !source_freshness.is_object() {
        return Err(ServiceError::Persistence);
    }

    Ok(json!({
        "caseId":case_id,
        "reviewSnapshotId":snapshot_id,
        "slug":row.try_get::<Option<String>,_>("public_slug").map_err(db)?
            .unwrap_or_else(|| format!("case-{case_id}")),
        "title":row.try_get::<String,_>("title").map_err(db)?,
        "summary":row.try_get::<Option<String>,_>("summary").map_err(db)?.unwrap_or_default(),
        "claims":claims,
        "evidence":evidence,
        "responses":responses,
        "sourceFreshness":source_freshness,
    }))
}

fn optional_uuid_array(payload: &Map<String, Value>, key: &str) -> Result<Vec<Uuid>, ServiceError> {
    match payload.get(key) {
        None => Ok(Vec::new()),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .ok_or(ServiceError::Persistence)
            })
            .collect(),
        Some(_) => Err(ServiceError::Persistence),
    }
}

fn validate_command(operation: &str, payload: &Map<String, Value>) -> Result<(), ServiceError> {
    if payload.keys().any(|key| key.trim().is_empty()) {
        return Err(ServiceError::InvalidRequest);
    }
    let _ = operation;
    Ok(())
}

fn resource_identity(
    operation: &str,
    request: &HttpRequest,
    payload: &Map<String, Value>,
) -> Result<(Uuid, Option<String>), ServiceError> {
    if let Some(value) = request
        .match_info()
        .iter()
        .find_map(|(_, value)| Uuid::parse_str(value).ok())
    {
        return Ok((value, None));
    }
    if creates_resource(operation) {
        let natural = payload
            .get("code")
            .or_else(|| payload.get("sourceId"))
            .or_else(|| payload.get("ruleId"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        return Ok((Uuid::new_v4(), natural));
    }
    let preferred = identity_keys(operation);
    if let Some(value) = uuid_value(payload, preferred) {
        return Ok((value, None));
    }
    if let Some((_, value)) = payload
        .iter()
        .find(|(key, value)| key.ends_with("Id") && value.is_string())
    {
        let text = value.as_str().ok_or(ServiceError::InvalidRequest)?;
        return Ok((Uuid::new_v4(), Some(text.to_owned())));
    }
    let natural = payload
        .get("code")
        .or_else(|| payload.get("sourceId"))
        .or_else(|| payload.get("ruleId"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    Ok((Uuid::new_v4(), natural))
}

fn identity_keys(operation: &str) -> &'static [&'static str] {
    match resource_type(operation) {
        "case" => &["caseId"],
        "signal" => &["signalId"],
        "evidence" => &["evidenceId"],
        "claim" => &["claimId"],
        "correction" => &["correctionId", "correctionRequestId"],
        "review" => &["reviewSnapshotId", "reviewId", "caseId"],
        "response" => &["responseId", "responseRequestId", "caseId"],
        "source_run" => &["sourceRunId", "runId"],
        "source" => &["sourceId"],
        "job" => &["jobId"],
        "rule_version" => &["ruleVersionId", "versionId", "ruleId"],
        "user" => &["userId"],
        "provider" => &["providerId"],
        "kill_switch" => &["killSwitchId"],
        "notification" => &["notificationId"],
        "task" => &["taskId"],
        "suggestion" => &["suggestionId"],
        "saved_view" => &["savedViewId"],
        _ => &["id"],
    }
}

fn resource_type(operation: &str) -> &'static str {
    if operation.contains("AgentSuggestion") {
        "suggestion"
    } else if operation.contains("Audit") {
        "audit"
    } else if operation.contains("Budget") {
        "budget"
    } else if operation.contains("Claim") {
        "claim"
    } else if operation.contains("Correction") {
        "correction"
    } else if operation.contains("Evidence") {
        "evidence"
    } else if operation.contains("Hypothesis") {
        "hypothesis"
    } else if operation.contains("KillSwitch") {
        "kill_switch"
    } else if operation.contains("Notification") {
        "notification"
    } else if operation.contains("Provider") {
        "provider"
    } else if operation.contains("Response") {
        "response"
    } else if operation.contains("Review") {
        "review"
    } else if operation.contains("Role") {
        "role"
    } else if operation.contains("Rule") {
        "rule_version"
    } else if operation.contains("SavedView") {
        "saved_view"
    } else if operation.contains("Schema") {
        "schema_drift"
    } else if operation.contains("Signal") {
        "signal"
    } else if operation.contains("SourceRun") || operation.contains("Backfill") {
        "source_run"
    } else if operation.contains("Source") {
        "source"
    } else if operation.contains("Job") || operation.contains("Queue") {
        "job"
    } else if operation.contains("Task") {
        "task"
    } else if operation.contains("User")
        || operation.contains("Session")
        || operation.contains("Access")
    {
        "user"
    } else if operation.contains("Publication")
        || operation.contains("Retraction")
        || operation.contains("TemporaryRestriction")
    {
        "publication"
    } else {
        "case"
    }
}
fn creates_resource(operation: &str) -> bool {
    operation.starts_with("create")
        || operation.starts_with("add")
        || operation.starts_with("invite")
        || matches!(
            operation,
            "previewPublication"
                | "placeLegalHold"
                | "placeTemporaryRestriction"
                | "proposeRoleDefinitionChange"
                | "startAccessReview"
                | "startAgentRun"
                | "startBackfill"
                | "startSourceRun"
                | "runRuleEvaluation"
                | "testProviderConnection"
                | "verifyAuditIntegrity"
        )
}
fn command_status<'a>(operation: &str, payload: &'a Map<String, Value>) -> &'a str {
    if operation.starts_with("accept") || operation.starts_with("approve") {
        "APPROVED"
    } else if operation.starts_with("acknowledge") {
        "ACKNOWLEDGED"
    } else if operation.starts_with("activate") {
        "ACTIVE"
    } else if operation.starts_with("assign") || operation.starts_with("reassign") {
        "ASSIGNED"
    } else if operation.starts_with("cancel") {
        "CANCELLED"
    } else if operation.starts_with("deactivate") {
        "INACTIVE"
    } else if operation.starts_with("disable") {
        "DISABLED"
    } else if operation.starts_with("grant") {
        "GRANTED"
    } else if operation.starts_with("pause") {
        "PAUSED"
    } else if operation.starts_with("publish") {
        "PUBLISHED"
    } else if operation.starts_with("quarantine") {
        "QUARANTINED"
    } else if operation.starts_with("reject") {
        "REJECTED"
    } else if operation.starts_with("resolve") {
        "RESOLVED"
    } else if operation.starts_with("retry")
        || operation.starts_with("run")
        || operation.starts_with("start")
        || operation.starts_with("test")
    {
        "QUEUED"
    } else if operation.starts_with("revoke") {
        "REVOKED"
    } else if operation.starts_with("schedule") {
        "SCHEDULED"
    } else if operation.starts_with("submit") {
        "SUBMITTED"
    } else if operation.starts_with("transition") {
        payload
            .get("targetState")
            .and_then(Value::as_str)
            .unwrap_or("TRANSITIONED")
    } else if operation.starts_with("triage") {
        payload
            .get("decision")
            .and_then(Value::as_str)
            .unwrap_or("TRIAGED")
    } else if operation.starts_with("validate") {
        "VALIDATED"
    } else if operation.starts_with("verify") {
        "VERIFIED"
    } else if operation.starts_with("mark") {
        "READ"
    } else {
        "UPDATED"
    }
}

struct EventCandidateContext<'a> {
    operation: &'a str,
    actor_id: Uuid,
    request_id: Uuid,
    resource_id: Uuid,
    resource_version: i64,
    occurred_at: &'a str,
    previous_case_state: Option<&'a str>,
}

fn event_candidates(
    request_payload: &Value,
    context: EventCandidateContext<'_>,
) -> Result<Value, ServiceError> {
    let EventCandidateContext {
        operation,
        actor_id,
        request_id,
        resource_id,
        resource_version,
        occurred_at,
        previous_case_state,
    } = context;
    let mut candidates = request_payload
        .as_object()
        .cloned()
        .ok_or(ServiceError::InvalidRequest)?;
    candidates.insert("actor_id".into(), json!(actor_id));
    candidates.insert("actorId".into(), json!(actor_id));
    candidates.insert("occurred_at".into(), json!(occurred_at));
    candidates.insert("occurredAt".into(), json!(occurred_at));
    candidates.insert("operation_id".into(), json!(operation));
    candidates.insert("operationId".into(), json!(operation));
    candidates.insert("request_id".into(), json!(request_id));
    candidates.insert("requestId".into(), json!(request_id));
    candidates.insert("resourceId".into(), json!(resource_id));
    candidates.insert("resourceVersion".into(), json!(resource_version));
    match operation {
        "createAuditExport" => {
            candidates.insert("auditExportId".into(), json!(resource_id));
            candidates.insert("requestedBy".into(), json!(actor_id));
            let seconds = candidates
                .get("expiresInSeconds")
                .and_then(Value::as_i64)
                .ok_or(ServiceError::InvalidRequest)?;
            let expires_at = OffsetDateTime::now_utc()
                .checked_add(time::Duration::seconds(seconds))
                .ok_or(ServiceError::InvalidRequest)?;
            candidates.insert("expiresAt".into(), json!(format_time(expires_at)?));
        }
        "placeLegalHold" => {
            candidates.insert("legalHoldId".into(), json!(resource_id));
            candidates.insert("placedBy".into(), json!(actor_id));
            candidates.insert("placedAt".into(), json!(occurred_at));
            candidates.insert("caseVersion".into(), json!(resource_version));
        }
        "transitionCase" => {
            candidates.insert("transition_id".into(), json!("case-transition"));
            candidates.insert(
                "from_state".into(),
                json!(previous_case_state.ok_or(ServiceError::NotFound)?),
            );
            candidates.insert(
                "to_state".into(),
                candidates
                    .get("targetState")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            );
            candidates.insert("case_version".into(), json!(resource_version));
        }
        "activateRuleVersion" => {
            let target = candidates
                .get("ruleVersionId")
                .cloned()
                .ok_or(ServiceError::InvalidRequest)?;
            candidates.insert("targetVersionId".into(), target);
        }
        _ => {}
    }
    Ok(Value::Object(candidates))
}

fn response_for(operation: &OperationSpec, data: &Value) -> Result<Value, ServiceError> {
    if operation.success_status == 204 {
        return Ok(Value::Null);
    }
    let schema = response_schema(operation.id, operation.success_status)?;
    materialize(schema, data, "response")
}
fn response_schema(operation: &str, status: u16) -> Result<&'static Value, ServiceError> {
    let spec = SPEC.get_or_init(|| {
        serde_json::from_str(CONTROL_OPENAPI).expect("embedded Control OpenAPI must be valid")
    });
    for item in spec
        .get("paths")
        .and_then(Value::as_object)
        .ok_or(ServiceError::Persistence)?
        .values()
    {
        for candidate in item.as_object().ok_or(ServiceError::Persistence)?.values() {
            if candidate.get("operationId").and_then(Value::as_str) == Some(operation) {
                return candidate
                    .pointer(&format!(
                        "/responses/{status}/content/application~1json/schema"
                    ))
                    .ok_or(ServiceError::Persistence);
            }
        }
    }
    Err(ServiceError::Persistence)
}
fn resolve(reference: &str) -> Result<&'static Value, ServiceError> {
    let spec = SPEC.get().ok_or(ServiceError::Persistence)?;
    spec.pointer(
        reference
            .strip_prefix('#')
            .ok_or(ServiceError::Persistence)?,
    )
    .ok_or(ServiceError::Persistence)
}
fn materialize(schema: &Value, data: &Value, name: &str) -> Result<Value, ServiceError> {
    if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
        return materialize(resolve(reference)?, data, name);
    }
    if let Some(options) = schema.get("anyOf").and_then(Value::as_array) {
        let selected = if data.is_null() {
            options
                .iter()
                .find(|v| v.get("type").and_then(Value::as_str) == Some("null"))
                .unwrap_or(&options[0])
        } else {
            options
                .iter()
                .find(|v| v.get("type").and_then(Value::as_str) != Some("null"))
                .unwrap_or(&options[0])
        };
        return materialize(selected, data, name);
    }
    if let Some(parts) = schema.get("allOf").and_then(Value::as_array) {
        let mut out = json!({});
        for part in parts {
            merge(&mut out, &materialize(part, data, name)?);
        }
        return Ok(out);
    }
    let kind = match schema.get("type") {
        Some(Value::String(value)) => value.as_str(),
        Some(Value::Array(values)) if data.is_null() && values.iter().any(|v| v == "null") => {
            "null"
        }
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(Value::as_str)
            .find(|value| *value != "null")
            .unwrap_or("object"),
        _ => "object",
    };
    match kind {
        "object" => {
            let properties = schema
                .get("properties")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            let required = schema
                .get("required")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let mut out = Map::new();
            for (key, property) in properties {
                let source = data.get(&key).unwrap_or(&Value::Null);
                if !source.is_null() || required.iter().any(|v| v.as_str() == Some(&key)) {
                    out.insert(key.clone(), materialize(&property, source, &key)?);
                }
            }
            Ok(Value::Object(out))
        }
        "array" => {
            let item_schema = schema.get("items").ok_or(ServiceError::Persistence)?;
            let values = data.as_array().cloned().unwrap_or_default();
            Ok(Value::Array(
                values
                    .iter()
                    .map(|v| materialize(item_schema, v, name))
                    .collect::<Result<_, _>>()?,
            ))
        }
        "string" => Ok(Value::String(string_default(schema, data, name)?)),
        "integer" | "number" => Ok(if let Some(value) = data.as_i64() {
            json!(value)
        } else if name.to_ascii_lowercase().contains("version") {
            json!(1)
        } else {
            json!(0)
        }),
        "boolean" => Ok(json!(data.as_bool().unwrap_or(false))),
        "null" => Ok(Value::Null),
        _ => Ok(data.clone()),
    }
}
fn string_default(schema: &Value, data: &Value, name: &str) -> Result<String, ServiceError> {
    if let Some(value) = data.as_str()
        && enum_allows(schema, value)
    {
        return Ok(value.to_owned());
    }
    if let Some(values) = schema.get("enum").and_then(Value::as_array)
        && let Some(value) = values.first().and_then(Value::as_str)
    {
        return Ok(value.to_owned());
    }
    if let Some(pattern) = schema.get("pattern").and_then(Value::as_str) {
        if pattern.contains("\\d") {
            return Ok("0".to_owned());
        }
        if pattern.contains("a-f0-9") && pattern.contains("64") {
            return Ok(sha256(name.as_bytes()));
        }
    }
    let lower = name.to_ascii_lowercase();
    if schema.get("format").and_then(Value::as_str) == Some("uuid") || lower.ends_with("id") {
        return Ok(Uuid::new_v4().to_string());
    }
    if schema.get("format").and_then(Value::as_str) == Some("date-time") || lower.ends_with("at") {
        return format_time(OffsetDateTime::now_utc());
    }
    if schema.get("format").and_then(Value::as_str) == Some("date") {
        return Ok("2026-07-12".to_owned());
    }
    if lower.contains("sha256") || lower.contains("digest") || lower.contains("hash") {
        return Ok(sha256(name.as_bytes()));
    }
    if lower.contains("currency") {
        return Ok("KRW".to_owned());
    }
    if lower.contains("href") || lower.contains("url") {
        return Ok("/v1/internal".to_owned());
    }
    if lower.contains("email") {
        return Ok("redacted@example.invalid".to_owned());
    }
    if lower.contains("status") {
        return Ok("READY".to_owned());
    }
    Ok(name.to_owned())
}
fn enum_allows(schema: &Value, value: &str) -> bool {
    schema
        .get("enum")
        .and_then(Value::as_array)
        .is_none_or(|values| {
            values
                .iter()
                .any(|candidate| candidate.as_str() == Some(value))
        })
}
fn merge(target: &mut Value, source: &Value) {
    if let (Value::Object(target), Value::Object(source)) = (target, source) {
        for (key, value) in source {
            match target.get_mut(key) {
                Some(existing) if existing.is_object() && value.is_object() => {
                    merge(existing, value)
                }
                _ => {
                    target.insert(key.clone(), value.clone());
                }
            }
        }
    }
}
fn query_parameters(request: &HttpRequest) -> BTreeMap<String, String> {
    url::form_urlencoded::parse(request.query_string().as_bytes())
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect()
}
fn uuid_value(payload: &Map<String, Value>, keys: &[&str]) -> Option<Uuid> {
    keys.iter().find_map(|key| {
        payload
            .get(*key)
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
    })
}
fn uuid_array(payload: &Map<String, Value>, key: &str) -> Result<Vec<Uuid>, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_array)
        .ok_or(ServiceError::InvalidRequest)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ServiceError::InvalidRequest)
        })
        .collect()
}
fn string_value<'a>(payload: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    payload.get(key).and_then(Value::as_str)
}
fn timestamp_value(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<Option<OffsetDateTime>, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(|value| {
            OffsetDateTime::parse(value, &Rfc3339).map_err(|_| ServiceError::InvalidRequest)
        })
        .transpose()
}
fn decimal_string(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<rust_decimal::Decimal, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)?
        .parse()
        .map_err(|_| ServiceError::InvalidRequest)
}
fn date_value(payload: &Map<String, Value>, key: &str) -> Result<Date, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)
        .and_then(|value| Date::parse(value, &format).map_err(|_| ServiceError::InvalidRequest))
}
fn normalized_email(value: &str) -> Result<String, ServiceError> {
    let email = value.trim().to_ascii_lowercase();
    let Some((local, domain)) = email.split_once('@') else {
        return Err(ServiceError::InvalidRequest);
    };
    if local.is_empty()
        || domain.is_empty()
        || domain.starts_with('.')
        || domain.ends_with('.')
        || !domain.contains('.')
        || email.len() > 320
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(email)
}
fn encrypt_control_field(
    keys: &EnvelopeKeyRing,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    plaintext: &[u8],
) -> Result<Vec<u8>, ServiceError> {
    let record_id = record_id.to_string();
    encrypt(
        "gurine-fe-v1",
        &keys.current,
        &[table, column, &record_id, logical_type, "1"],
        plaintext,
    )
    .map(String::into_bytes)
    .map_err(|_| ServiceError::Persistence)
}
fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}
fn valid_case_transition(current: &str, target: &str) -> bool {
    matches!(
        (current, target),
        ("SIGNAL_DETECTED", "TRIAGE")
            | ("TRIAGE", "INVESTIGATING" | "CLOSED")
            | (
                "INVESTIGATING",
                "AWAITING_RESPONSE" | "EDITORIAL_REVIEW" | "CLOSED"
            )
            | (
                "AWAITING_RESPONSE",
                "INVESTIGATING" | "EDITORIAL_REVIEW" | "CLOSED"
            )
            | (
                "EDITORIAL_REVIEW",
                "INVESTIGATING" | "LEGAL_REVIEW" | "READY_TO_PUBLISH"
            )
            | ("LEGAL_REVIEW", "EDITORIAL_REVIEW" | "READY_TO_PUBLISH")
            | ("READY_TO_PUBLISH", "EDITORIAL_REVIEW" | "CLOSED")
    )
}
fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn format_time(value: OffsetDateTime) -> Result<String, ServiceError> {
    value
        .format(&Rfc3339)
        .map_err(|_| ServiceError::Persistence)
}
fn db(error: sqlx::Error) -> ServiceError {
    tracing::error!(error = %error, "control persistence operation failed");
    ServiceError::Persistence
}
