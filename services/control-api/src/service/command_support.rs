fn required_sqlx_value<T>(value: Option<T>) -> Result<T, ServiceError> {
    value.ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })
}

async fn append_audit_event(
    operation: &OperationSpec,
    actor_id: Uuid,
    session_id: Uuid,
    request_id: Uuid,
    key: &CommandKey,
    prepared: &PreparedCommand,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Uuid, ServiceError> {
    let action = command_audit_action(operation.id);
    let capability = prepared
        .canonical_payload
        .get("_actorEffectiveCapability")
        .and_then(Value::as_str)
        .unwrap_or(operation.capability);
    let audit_event_id = sqlx::query_scalar!(
        "SELECT ops.append_audit_event($1,'USER',$2,$3,$4,$5,$6,$7,'SUCCESS',$8,$9,$10)",
        format!("control:{}:{}", prepared.resource_type, prepared.persisted_id),
        actor_id.to_string(),
        session_id,
        action,
        prepared.resource_type,
        prepared.persisted_id.to_string(),
        capability,
        None::<&str>,
        request_id,
        json!({"resourceVersion":prepared.version,"operationId":operation.id,"requestSha256":key.request_hash}),
    )
        .fetch_one(&mut **transaction)
        .await
        .map_err(db)?;
    required_sqlx_value(audit_event_id)
}

fn command_audit_action(operation: &str) -> String {
    format!("command.{operation}")
}

async fn enqueue_command_events(
    operation: &OperationSpec,
    candidates: &Value,
    prepared: &PreparedCommand,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Vec<PendingDomainEvent>, ServiceError> {
    let mut pending = Vec::new();
    for event_type in producer_events(operation.id) {
        let event_payload =
            project_payload(event_type, candidates).map_err(|_| ServiceError::InvalidRequest)?;
        if requires_outbox(event_type) {
            sqlx::query!(
                "SELECT ops.enqueue_outbox($1,$2,$3,$4,$5,$6)",
                prepared.resource_type,
                prepared.persisted_id.to_string(),
                prepared.version,
                event_type,
                event_payload,
                prepared.occurred_at,
            )
            .fetch_one(&mut **transaction)
            .await
            .map_err(db)?;
        } else {
            pending.push(PendingDomainEvent {
                event_type,
                aggregate_id: prepared.persisted_id.to_string(),
                version: prepared.version,
                payload: event_payload,
            });
        }
    }
    Ok(pending)
}

async fn validate_transition_case(
    operation: &str,
    payload: &Map<String, Value>,
    claims: &ActorClaims,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if operation != "transitionCase" {
        return Ok(());
    }
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let target = string_value(payload, "targetState").ok_or(ServiceError::InvalidRequest)?;
    let reason = string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?;
    let row = sqlx::query!(
        "SELECT c.investigation_state::text current_state,c.publication_state::text publication_state, \
         c.resolution_code::text resolution_code,c.lead_investigator_id IS NOT NULL assigned_investigator, \
         EXISTS(SELECT 1 FROM editorial.case_signals cs WHERE cs.case_id=c.id) at_least_one_signal, \
         EXISTS(SELECT 1 FROM editorial.case_signals cs JOIN ops.signal_triages st ON st.signal_id=cs.signal_id \
           WHERE cs.case_id=c.id AND st.result IN ('PROMOTE_TO_CASE','LINK_TO_CASE')) triage_decision_investigate, \
         EXISTS(SELECT 1 FROM editorial.response_requests r WHERE r.case_id=c.id \
           AND r.status IN ('SENT','VIEWED') AND r.due_at>clock_timestamp()) validated_response_request, \
         EXISTS(SELECT 1 FROM editorial.response_requests r WHERE r.case_id=c.id \
           AND r.status IN ('SENT','VIEWED') AND r.due_at>clock_timestamp()) due_at_in_future, \
         EXISTS(SELECT 1 FROM editorial.responses r WHERE r.case_id=c.id AND r.verified_at IS NOT NULL) \
           OR EXISTS(SELECT 1 FROM editorial.response_requests r WHERE r.case_id=c.id \
             AND (r.status IN ('SUBMITTED','CLOSED','EXPIRED') OR r.due_at<=clock_timestamp())) \
           response_received_or_deadline_handled, \
         EXISTS(SELECT 1 FROM editorial.claims cl WHERE cl.case_id=c.id) \
           AND NOT EXISTS(SELECT 1 FROM editorial.claims cl WHERE cl.case_id=c.id \
             AND cl.validation_status<>'VALID') claims_valid, \
         EXISTS(SELECT 1 FROM editorial.evidence e WHERE e.case_id=c.id) \
           AND NOT EXISTS(SELECT 1 FROM editorial.evidence e WHERE e.case_id=c.id \
             AND e.verification_status<>'VERIFIED') evidence_verified, \
         NOT EXISTS(SELECT 1 FROM editorial.response_requests r WHERE r.case_id=c.id \
           AND r.status IN ('DRAFT','SENT','VIEWED')) response_policy_satisfied, \
         c.legal_review_required legal_review_required, \
         EXISTS(SELECT 1 FROM editorial.review_snapshots s WHERE s.id=c.current_review_snapshot_id \
           AND s.case_id=c.id AND s.case_version=c.version AND s.unresolved_blockers='[]'::jsonb) snapshot_current, \
         EXISTS(SELECT 1 FROM editorial.review_decisions d \
           JOIN ops.user_roles ur ON ur.user_id=d.reviewer_id AND ur.revoked_at IS NULL \
             AND (ur.expires_at IS NULL OR ur.expires_at>clock_timestamp()) \
           JOIN ops.roles role ON role.id=ur.role_id AND role.code='EDITOR' \
           WHERE d.review_snapshot_id=c.current_review_snapshot_id AND d.decision='APPROVE') editorial_approved, \
         EXISTS(SELECT 1 FROM editorial.review_decisions d \
           JOIN ops.user_roles ur ON ur.user_id=d.reviewer_id AND ur.revoked_at IS NULL \
             AND (ur.expires_at IS NULL OR ur.expires_at>clock_timestamp()) \
           JOIN ops.roles role ON role.id=ur.role_id AND role.code='LEGAL_REVIEWER' \
           WHERE d.review_snapshot_id=c.current_review_snapshot_id AND d.decision='APPROVE') legal_approved, \
         EXISTS(SELECT 1 FROM editorial.evidence e WHERE e.case_id=c.id AND e.created_at>c.updated_at) \
           new_material_evidence, \
         c.publication_state='NEVER_PUBLISHED' OR COALESCE(to_timestamp($2),'-infinity'::timestamptz) > \
           COALESCE((SELECT max(p.published_at) FROM editorial.publication_revisions p WHERE p.case_id=c.id),'-infinity'::timestamptz) \
           reauth_if_previously_published \
         FROM editorial.cases c WHERE c.id=$1",
        case_id,
        claims.auth_time as f64,
    )
    .fetch_optional(&mut **transaction)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let current = investigation_state(required_sqlx_value(row.current_state.as_deref())?)
        .ok_or(ServiceError::Persistence)?;
    let target = investigation_state(target).ok_or(ServiceError::InvalidRequest)?;
    let transition = CASE_TRANSITIONS
        .iter()
        .find(|candidate| candidate.from.contains(&current) && candidate.to == target)
        .ok_or(ServiceError::InvalidStateTransition)?;
    if !claims
        .capabilities
        .iter()
        .any(|capability| capability == transition.capability)
    {
        return Err(ServiceError::CapabilityDenied);
    }
    let structured_reason = {
        let reason = reason.trim();
        (10..=4000).contains(&reason.chars().count())
    };
    let satisfied = |guard: &str| -> Result<bool, ServiceError> {
        match guard {
            "at_least_one_signal" => required_sqlx_value(row.at_least_one_signal),
            "triage_decision_investigate" => required_sqlx_value(row.triage_decision_investigate),
            "assigned_investigator" => required_sqlx_value(row.assigned_investigator),
            "validated_response_request" => required_sqlx_value(row.validated_response_request),
            "due_at_in_future" => required_sqlx_value(row.due_at_in_future),
            "response_received_or_deadline_handled" => {
                required_sqlx_value(row.response_received_or_deadline_handled)
            }
            "claims_valid" => required_sqlx_value(row.claims_valid),
            "evidence_verified" => required_sqlx_value(row.evidence_verified),
            "response_policy_satisfied" => required_sqlx_value(row.response_policy_satisfied),
            "editorial_approved" => required_sqlx_value(row.editorial_approved),
            "legal_review_required" => Ok(row.legal_review_required),
            "snapshot_current" => required_sqlx_value(row.snapshot_current),
            "legal_approved" => required_sqlx_value(row.legal_approved),
            "new_material_evidence" => required_sqlx_value(row.new_material_evidence),
            "reauth_if_previously_published" => {
                required_sqlx_value(row.reauth_if_previously_published)
            }
            "legal_review_not_required" => Ok(!row.legal_review_required),
            "changes_required_reason" | "structured_reason" => Ok(structured_reason),
            "resolution_code_not_none" => {
                required_sqlx_value(row.resolution_code.as_deref()).map(|code| code != "NONE")
            }
            _ => Err(ServiceError::Persistence),
        }
    };
    for guard in transition.guards {
        if !satisfied(guard)? {
            return Err(ServiceError::PreconditionFailed);
        }
    }
    Ok(())
}

pub(super) async fn canonical_guard(
    operation: &str,
    payload: &Map<String, Value>,
    actor: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Option<i64>, ServiceError> {
    let catalog = CONCURRENCY
        .get_or_init(|| serde_json::from_str(CONCURRENCY_JSON).map_err(|_| ()))
        .as_ref()
        .map_err(|_| ServiceError::Persistence)?;
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
    canonical_guard_miss(
        contract,
        &identity,
        identity_column,
        owner_guard,
        status_guard,
        owner_predicate,
        actor,
        transaction,
    )
    .await
}

async fn canonical_guard_miss(
    contract: &ConcurrencyContract,
    identity: &str,
    identity_column: &str,
    owner_guard: bool,
    status_guard: Option<&str>,
    owner_predicate: &str,
    actor: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Option<i64>, ServiceError> {
    if let Some(required_status) = status_guard {
        let probe = format!(
            "SELECT status::text FROM {relation} WHERE {identity_column}::text=$1{owner_predicate}",
            relation = contract.guard_relation,
        );
        let mut query =
            sqlx::query_scalar::<_, String>(AssertSqlSafe(probe.as_str())).bind(&identity);
        if owner_guard {
            query = query.bind(actor);
        }
        return match query.fetch_optional(&mut **transaction).await.map_err(db)? {
            None => Err(ServiceError::NotFound),
            Some(actual) if actual != required_status => Err(ServiceError::InvalidStateTransition),
            Some(_) => Err(ServiceError::VersionConflict),
        };
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

pub(super) async fn canonical_identity(
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
        let case_id = sqlx::query_scalar!(
            "SELECT case_id FROM editorial.publication_revisions WHERE id=$1",
            publication,
        )
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

pub(super) fn canonical_status_guard(operation: &str) -> Option<&'static str> {
    match operation {
        "acknowledgeSourceIncident" => Some("OPEN"),
        "acceptAgentSuggestion" | "rejectAgentSuggestion" => Some("PENDING"),
        "approveSchemaMapping" | "rejectSchemaMapping" => Some("OPEN"),
        "pauseBackfill" => Some("RUNNING"),
        "resolveCorrectionRequest" => Some("REVIEW"),
        "saveResponseRequestDraft" => Some("DRAFT"),
        _ => None,
    }
}

pub(super) fn safe_sql_identifier(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.'))
}

struct TriageSignalDetails<'a> {
    decision: &'a str,
    result: &'static str,
    reason: &'a str,
    signal_id: Uuid,
    expected_version: i64,
    duplicate_target: Option<Uuid>,
    duplicate_relationship: Option<&'a str>,
    expected_duplicate_version: Option<i64>,
}

fn triage_signal_details(
    prepared: &PreparedCommand,
) -> Result<TriageSignalDetails<'_>, ServiceError> {
    let payload = &prepared.payload;
    let decision = payload
        .get("decision")
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)?;
    let result = triage_result(decision)?;
    let reason = payload
        .get("reason")
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)?;
    let signal_id = payload
        .get("signalId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    let expected_version = payload
        .get("expectedVersion")
        .and_then(Value::as_i64)
        .ok_or(ServiceError::InvalidRequest)?;
    let duplicate_target = if result == "MARK_DUPLICATE" {
        Some(
            payload
                .get("duplicateSignalId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ServiceError::InvalidRequest)?,
        )
    } else {
        None
    };
    let duplicate_relationship = (result == "MARK_DUPLICATE").then(|| {
        payload
            .get("duplicateRelationship")
            .and_then(Value::as_str)
            .unwrap_or("SAME_LOGICAL_EVENT")
    });
    let expected_duplicate_version = if result == "MARK_DUPLICATE" {
        Some(
            payload
                .get("expectedDuplicateSignalVersion")
                .and_then(Value::as_i64)
                .ok_or(ServiceError::InvalidRequest)?,
        )
    } else {
        None
    };
    Ok(TriageSignalDetails {
        decision,
        result,
        reason,
        signal_id,
        expected_version,
        duplicate_target,
        duplicate_relationship,
        expected_duplicate_version,
    })
}

fn append_triage_receipt_data(
    receipt_data: &mut Value,
    details: &TriageSignalDetails<'_>,
) -> Result<(String, String), ServiceError> {
    let mut binding = json!({
        "signalId": details.signal_id,
        "expectedSignalVersion": details.expected_version,
        "decision": details.decision,
        "reason": details.reason,
    });
    if let Some(target) = details.duplicate_target {
        binding = json!({
            "signalId": details.signal_id,
            "expectedSignalVersion": details.expected_version,
            "duplicateSignalId": target,
            "expectedDuplicateSignalVersion": details.expected_duplicate_version,
            "duplicateRelationship": details.duplicate_relationship,
            "reason": details.reason,
        });
    }
    let reason_digest =
        sha256(&serde_json::to_vec(&binding).map_err(|_| ServiceError::InvalidRequest)?);
    let object = receipt_data
        .as_object_mut()
        .ok_or(ServiceError::InvalidRequest)?;
    object.insert("result".into(), json!(details.result));
    object.insert("reasonDigest".into(), json!(reason_digest));
    if let Some(target) = details.duplicate_target {
        object.insert("duplicateSignalId".into(), json!(target));
        object.insert(
            "duplicateRelationship".into(),
            json!(details.duplicate_relationship),
        );
    }
    let receipt_digest = serde_json::to_vec(receipt_data)
        .map(|bytes| sha256(&bytes))
        .map_err(|_| ServiceError::InvalidRequest)?;
    Ok((reason_digest, receipt_digest))
}

#[expect(
    clippy::too_many_arguments,
    reason = "triage receipt persistence binds aggregate, actor, request, and digest evidence"
)]
async fn persist_triage_signal(
    prepared: &PreparedCommand,
    details: &TriageSignalDetails<'_>,
    actor_id: Uuid,
    request_id: Uuid,
    audit_event_id: Uuid,
    reason_digest: &str,
    receipt_digest: &str,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    sqlx::query!(
        "INSERT INTO ops.signal_triages(signal_id,prior_version,resulting_version,result,decision,reason_digest,duplicate_signal_id,duplicate_relationship,expected_duplicate_signal_version,actor_id,request_id,audit_event_id,receipt_digest)          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
        prepared.persisted_id,
        details.expected_version,
        prepared.version,
        details.result,
        match details.decision {
            "DISMISS" => "dismiss",
            "NEEDS_DATA" => "needs_data",
            "MARK_DUPLICATE" => "duplicate",
            "PROMOTE_TO_CASE" => "investigate",
            "LINK_TO_CASE" => "link",
            value => value,
        },
        reason_digest,
        details.duplicate_target,
        details.duplicate_relationship,
        details.expected_duplicate_version,
        actor_id,
        request_id,
        audit_event_id,
        receipt_digest,
    )
    .execute(&mut **transaction)
    .await
    .map_err(db)?;
    Ok(())
}
