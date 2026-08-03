use super::*;

pub(super) async fn case_query(
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

pub(super) async fn evidence_query(
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

pub(super) async fn dashboard_query(
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
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

pub(super) async fn source_query(
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

pub(super) async fn job_query(
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

pub(super) async fn operations_query(pool: &PgPool) -> Result<Value, ServiceError> {
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

pub(super) async fn publication_preview_query(
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

pub(super) async fn publication_receipt_query(
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

pub(super) async fn publish_confirmation_query(
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

pub(super) async fn review_snapshot_query(
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

pub(super) async fn schema_drift_query(
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

pub(super) async fn signal_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "signalId")?;
    let signal: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',s.id,'ruleRunId',s.rule_run_id, \
         'ruleVersionId',s.rule_version_id,'signalType',s.signal_type,'targetType',s.target_type, \
         'targetId',s.target_id,'score',s.score,'severity',s.severity,'status',s.status::text, \
         'explanation',s.explanation,'calculation',s.calculation,'blockers',s.blockers, \
         'comparisonDigest',s.comparison_digest,'assignedUserId',s.assigned_user_id,'version',s.version, \
         'duplicateSignalId',s.duplicate_signal_id,'duplicateRelationship',s.duplicate_relationship, \
         'duplicateReasonDigest',s.duplicate_reason_digest,'duplicateMarkedBy',s.duplicate_marked_by, \
         'duplicateMarkedAt',s.duplicate_marked_at) \
         FROM core.anomaly_signals s WHERE s.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let duplicates: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',d.id,'signalType',d.signal_type,
          'severity',d.severity,'status',d.status::text,'targetType',d.target_type,
          'targetId',d.target_id,'explanation',d.explanation,'createdAt',d.created_at,
          'assignedUserId',d.assigned_user_id,'duplicateRelationship',d.duplicate_relationship)
          ORDER BY d.created_at DESC),'[]'::jsonb)
           FROM core.anomaly_signals d
          WHERE d.id=(SELECT duplicate_signal_id FROM core.anomaly_signals WHERE id=$1)
             OR d.duplicate_signal_id=$1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    Ok(
        json!({"signal":signal,"triggerExplanation":signal.get("explanation").cloned().unwrap_or(json!({})),
        "dataQuality":{},"targetRecord":{},"duplicates":duplicates,
        "blockers":signal.get("blockers").cloned().unwrap_or(json!([])),
        "recommendedActions":[],"auditSummary":{}}),
    )
}

pub(super) async fn source_run_query(
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

pub(super) async fn user_access_query(
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
