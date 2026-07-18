use super::*;

/// OPS-004 typed business-health read boundary.  The SQL owner function is the
/// only source for funnel/metric derivation; this adapter only binds the
/// request scope and wraps the closed response in the control envelope.
pub(super) async fn business_health_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    // getBudgetOverview has historically had an empty query contract.  Keep
    // the scope optional for that operation, while accepting an explicit
    // deployment/organization pair for callers that need a single scope.
    let deployment_id = parameters
        .get("deploymentId")
        .map(|value| Uuid::parse_str(value).map_err(|_| ServiceError::InvalidRequest))
        .transpose()?;
    let organization_id = parameters
        .get("organizationId")
        .map(|value| Uuid::parse_str(value).map_err(|_| ServiceError::InvalidRequest))
        .transpose()?;
    let as_of = parameters
        .get("asOf")
        .map(|value| {
            OffsetDateTime::parse(value, &Rfc3339).map_err(|_| ServiceError::InvalidRequest)
        })
        .transpose()?;
    let data: Value = sqlx::query_scalar("SELECT ops.read_business_health_projection_v1($1,$2,$3)")
        .bind(deployment_id)
        .bind(organization_id)
        .bind(as_of)
        .fetch_one(pool)
        .await
        .map_err(db)?;
    let status = data
        .get("readinessState")
        .and_then(Value::as_str)
        .unwrap_or("UNKNOWN")
        .to_owned();
    let scope_key = format!(
        "{}:{}",
        deployment_id
            .map(|id| id.to_string())
            .unwrap_or_else(|| "*".to_owned()),
        organization_id
            .map(|id| id.to_string())
            .unwrap_or_else(|| "*".to_owned()),
    );
    Ok(envelope(
        stable_uuid("business-health", &scope_key),
        status,
        data,
    ))
}

pub(super) async fn estimate_backfill_query(
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

pub(super) async fn source_run_download(
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

pub(super) async fn cost_export_query(
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

pub(super) fn query_date(
    parameters: &BTreeMap<String, String>,
    name: &str,
) -> Result<Date, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    parameters
        .get(name)
        .ok_or(ServiceError::InvalidRequest)
        .and_then(|value| Date::parse(value, &format).map_err(|_| ServiceError::InvalidRequest))
}

pub(super) fn stable_uuid(namespace: &str, value: &str) -> Uuid {
    let digest = Sha256::digest(format!("gurine:{namespace}:{value}").as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

pub(super) async fn canonical_list_query(
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
        "listSignals" => sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'signalType',signal_type,'targetType',target_type,'targetId',target_id,'score',score,'severity',severity,'status',status::text,'assignedUserId',assigned_user_id,'version',version,'createdAt',created_at,'duplicateSignalId',duplicate_signal_id,'duplicateRelationship',duplicate_relationship) ORDER BY created_at DESC),'[]'::jsonb) FROM core.anomaly_signals").fetch_one(pool).await.map_err(db)?,
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

pub(super) async fn audit_query(
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
