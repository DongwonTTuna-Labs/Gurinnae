async fn append_audit_event(
    operation: &OperationSpec,
    actor_id: Uuid,
    session_id: Uuid,
    request_id: Uuid,
    key: &CommandKey,
    prepared: &PreparedCommand,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Uuid, ServiceError> {
    sqlx::query_scalar::<_, Uuid>("SELECT ops.append_audit_event($1,'USER',$2,$3,$4,$5,$6,$7,'SUCCESS',NULL,$8,$9)")
        .bind(format!("control:{}:{}", prepared.resource_type, prepared.persisted_id))
        .bind(actor_id.to_string()).bind(session_id).bind(format!("command.{}", operation.id)).bind(prepared.resource_type)
        .bind(prepared.persisted_id.to_string()).bind(operation.capability).bind(request_id)
        .bind(json!({"resourceVersion":prepared.version,"operationId":operation.id,"requestSha256":key.request_hash}))
        .fetch_one(&mut **transaction).await.map_err(db)
}

async fn enqueue_command_events(
    operation: &OperationSpec,
    candidates: &Value,
    prepared: &PreparedCommand,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    for event_type in producer_events(operation.id) {
        let event_payload =
            project_payload(event_type, candidates).map_err(|_| ServiceError::InvalidRequest)?;
        if requires_outbox(event_type) {
            sqlx::query("SELECT ops.enqueue_outbox($1,$2,$3,$4,$5,$6)")
                .bind(prepared.resource_type)
                .bind(prepared.persisted_id.to_string())
                .bind(prepared.version)
                .bind(event_type)
                .bind(event_payload)
                .bind(prepared.occurred_at)
                .fetch_one(&mut **transaction)
                .await
                .map_err(db)?;
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
    sqlx::query(
        "INSERT INTO ops.signal_triages(signal_id,prior_version,resulting_version,result,decision,reason_digest,duplicate_signal_id,duplicate_relationship,expected_duplicate_signal_version,actor_id,request_id,audit_event_id,receipt_digest)          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
    )
    .bind(prepared.persisted_id)
    .bind(details.expected_version)
    .bind(prepared.version)
    .bind(details.result)
    .bind(match details.decision {
        "DISMISS" => "dismiss",
        "NEEDS_DATA" => "needs_data",
        "MARK_DUPLICATE" => "duplicate",
        "PROMOTE_TO_CASE" => "investigate",
        "LINK_TO_CASE" => "link",
        value => value,
    })
    .bind(reason_digest)
    .bind(details.duplicate_target)
    .bind(details.duplicate_relationship)
    .bind(details.expected_duplicate_version)
    .bind(actor_id)
    .bind(request_id)
    .bind(audit_event_id)
    .bind(receipt_digest)
    .execute(&mut **transaction)
    .await
    .map_err(db)?;
    Ok(())
}
