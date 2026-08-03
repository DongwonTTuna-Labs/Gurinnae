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
