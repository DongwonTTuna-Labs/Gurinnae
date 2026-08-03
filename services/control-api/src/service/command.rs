use super::*;

pub(super) async fn command(
    handler: registry::CommandHandler,
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    claims: &ActorClaims,
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    domain_events: &Mutex<InProcessDomainEventJournal>,
    request_id: Uuid,
) -> Result<Output, ServiceError> {
    let payload = parse_command_payload(body)?;
    let payload_object = payload.as_object().ok_or(ServiceError::InvalidRequest)?;
    if operation.id == "createResponseRequest"
        && let Some(email) = payload_object.get("recipientEmail").and_then(Value::as_str)
        && !valid_recipient_email(email)
    {
        return Err(ServiceError::InvalidRequest);
    }
    validate_command(operation.id, payload_object)?;
    match domains::command_kind(handler) {
        domains::CommandKind::Addendum => {
            return addendum_command(
                operation, request, body, claims, pool, field_keys, request_id, payload,
            )
            .await;
        }
        domains::CommandKind::Private => return Err(ServiceError::InvalidRequest),
        domains::CommandKind::Base => {}
    }
    let actor_id = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let session_id = Uuid::parse_str(&claims.sid).map_err(|_| ServiceError::InvalidRequest)?;
    let (mut transaction, key, replay) =
        begin_idempotency(pool, operation, request, body, claims).await?;
    if let Some(response) = replay {
        transaction.commit().await.map_err(db)?;
        return Ok(response);
    }
    let previous_case_state =
        previous_case_state(operation.id, payload_object, &mut transaction).await?;
    validate_transition_case(operation.id, payload_object, claims, &mut transaction).await?;
    let mut prepared = prepare_command(
        operation,
        request,
        &payload,
        payload_object,
        actor_id,
        &mut transaction,
    )
    .await?;
    domains::apply_command(
        handler,
        operation.id,
        &prepared.canonical_payload,
        prepared.persisted_id,
        actor_id,
        session_id,
        field_keys,
        &mut transaction,
    )
    .await?;
    schedule_rule_activation(
        operation,
        payload_object,
        actor_id,
        request_id,
        &mut transaction,
    )
    .await?;
    let (response, pending_domain_events) = finalize_command(
        operation,
        &payload,
        actor_id,
        session_id,
        request_id,
        previous_case_state.as_deref(),
        &key,
        &mut prepared,
        &mut transaction,
    )
    .await?;
    transaction.commit().await.map_err(db)?;
    emit_domain_events(domain_events, pending_domain_events)?;
    Ok(response)
}

fn emit_domain_events(
    domain_events: &Mutex<InProcessDomainEventJournal>,
    pending_domain_events: Vec<PendingDomainEvent>,
) -> Result<(), ServiceError> {
    let mut domain_event_sink = domain_events
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    for event in pending_domain_events {
        if DomainEventSink::append(
            &mut *domain_event_sink,
            event.event_type,
            &event.aggregate_id,
            event.version,
            &event.payload,
        )
        .is_err()
        {
            return Err(ServiceError::Persistence);
        }
        tracing::info!(
            event_type = event.event_type,
            aggregate_id = event.aggregate_id,
            version = event.version,
            "committed in-process domain event emitted"
        );
    }
    Ok(())
}

fn valid_recipient_email(value: &str) -> bool {
    let trimmed = value.trim();
    let Some((local, domain)) = trimmed.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !trimmed.chars().any(char::is_whitespace)
}

include!("command_addendum.rs");

fn parse_command_payload(body: &[u8]) -> Result<Value, ServiceError> {
    if body.is_empty() {
        Ok(json!({}))
    } else {
        serde_json::from_slice::<Value>(body).map_err(|_| ServiceError::InvalidRequest)
    }
}

struct CommandKey {
    scope: String,
    key_hash: String,
    request_hash: String,
}

async fn begin_idempotency<'a>(
    pool: &'a PgPool,
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    claims: &ActorClaims,
) -> Result<(Transaction<'a, Postgres>, CommandKey, Option<Output>), ServiceError> {
    let idempotency_key = request
        .headers()
        .get("idempotency-key")
        .and_then(|value| value.to_str().ok())
        .filter(|value| (8..=200).contains(&value.len()) && value.is_ascii())
        .ok_or(ServiceError::InvalidRequest)?;
    let key = CommandKey {
        scope: format!("control:{}:{}", claims.sub, operation.id),
        key_hash: sha256(idempotency_key.as_bytes()),
        request_hash: canonical_request_digest(&BoundRequest {
            method: request.method().as_str(),
            path: request.path(),
            raw_query: request.query_string(),
            body,
            content_type: request
                .headers()
                .get("content-type")
                .and_then(|value| value.to_str().ok()),
            idempotency_key: Some(idempotency_key),
        })
        .map_err(|_| ServiceError::InvalidRequest)?,
    };
    let mut transaction = pool.begin().await.map_err(db)?;
    // All control mutations share the same serializable boundary.  Journey
    // owner routines require this before their first statement; applying it
    // here also prevents a caller from accidentally running a mixed-strength
    // transaction through the generic dispatcher.
    sqlx::query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *transaction)
        .await
        .map_err(db)?;
    let claimed = sqlx::query(
        "INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) \
         VALUES($1,$2,$3,clock_timestamp()+interval '24 hours') \
         ON CONFLICT(scope,key_hash) DO UPDATE SET \
         request_hash=EXCLUDED.request_hash,response_status=NULL,response_body=NULL, \
         resource_type=NULL,resource_id=NULL,created_at=clock_timestamp(), \
         expires_at=EXCLUDED.expires_at \
         WHERE ops.idempotency_keys.expires_at<=clock_timestamp()",
    )
    .bind(&key.scope)
    .bind(&key.key_hash)
    .bind(&key.request_hash)
    .execute(&mut *transaction)
    .await
    .map_err(db)?
    .rows_affected();
    let receipt = sqlx::query(
        "SELECT request_hash,response_status,response_body FROM ops.idempotency_keys \
         WHERE scope=$1 AND key_hash=$2 AND expires_at>clock_timestamp() FOR UPDATE",
    )
    .bind(&key.scope)
    .bind(&key.key_hash)
    .fetch_optional(&mut *transaction)
    .await
    .map_err(db)?
    .ok_or(ServiceError::IdempotencyConflict)?;
    if receipt
        .try_get::<String, _>("request_hash")
        .map_err(db)?
        .trim()
        != key.request_hash
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    let replay = if claimed == 0 {
        replay_output(&receipt)?.ok_or(ServiceError::IdempotencyConflict)?
    } else {
        return Ok((transaction, key, None));
    };
    Ok((transaction, key, Some(replay)))
}

fn replay_output(row: &sqlx::postgres::PgRow) -> Result<Option<Output>, ServiceError> {
    let Some(status) = row
        .try_get::<Option<i32>, _>("response_status")
        .map_err(db)?
    else {
        return Ok(None);
    };
    let Some(response) = row
        .try_get::<Option<Value>, _>("response_body")
        .map_err(db)?
    else {
        return Ok(None);
    };
    Ok(Some(Output {
        status: status as u16,
        media_type: if status == 204 {
            ""
        } else {
            "application/json"
        },
        body: response,
        replay: true,
    }))
}

async fn previous_case_state(
    operation: &str,
    payload: &Map<String, Value>,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Option<String>, ServiceError> {
    if operation != "transitionCase" {
        return Ok(None);
    }
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query_scalar::<_, String>(
        "SELECT investigation_state::text FROM editorial.cases WHERE id=$1 FOR UPDATE",
    )
    .bind(case_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(db)?
    .map(Some)
    .ok_or(ServiceError::NotFound)
}

struct PreparedCommand {
    canonical_payload: Map<String, Value>,
    payload: Value,
    resource_type: &'static str,
    persisted_id: Uuid,
    version: i64,
    status_code: u16,
    occurred_at: OffsetDateTime,
    occurred_text: String,
}

struct PendingDomainEvent {
    event_type: &'static str,
    aggregate_id: String,
    version: i64,
    payload: Value,
}

async fn prepare_command(
    operation: &OperationSpec,
    request: &HttpRequest,
    payload: &Value,
    payload_object: &Map<String, Value>,
    actor_id: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<PreparedCommand, ServiceError> {
    let canonical_payload = command_parameters(request, payload_object);
    if operation.id == "publishCase" {
        let case_id =
            uuid_value(payload_object, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
        let snapshot_id = uuid_value(payload_object, &["reviewSnapshotId"])
            .ok_or(ServiceError::InvalidRequest)?;
        let valid = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM editorial.review_snapshots s \
             JOIN editorial.cases c ON c.id=s.case_id \
             WHERE s.id=$1 AND s.case_id=$2 AND c.current_review_snapshot_id=$1 \
               AND s.unresolved_blockers='[]'::jsonb)",
        )
        .bind(snapshot_id)
        .bind(case_id)
        .fetch_one(&mut **transaction)
        .await
        .map_err(db)?;
        if !valid {
            return Err(ServiceError::InvalidRequest);
        }
    }
    // These specialized handlers own their optimistic update and therefore
    // must validate the expected version and mutate the aggregate atomically.
    // Running the generic guard first would increment the row before the
    // handler sees it, causing a false VERSION_CONFLICT or a double advance.
    let canonical_version = if matches!(
        operation.id,
        "triageSignal" | "acceptAgentSuggestion" | "rejectAgentSuggestion"
    ) {
        None
    } else {
        canonical_guard(operation.id, &canonical_payload, actor_id, transaction).await?
    };
    let resource_type = resource_type(operation.id);
    let (persisted_id, _) = resource_identity(operation.id, request, payload_object)?;
    let expected_version = payload_object
        .get("expectedVersion")
        .and_then(Value::as_i64);
    let version =
        canonical_version.unwrap_or_else(|| expected_version.map_or(1, |value| value + 1));
    let mut data = payload.clone();
    let occurred_at = OffsetDateTime::now_utc();
    let occurred_text = occurred_at
        .format(&Rfc3339)
        .map_err(|_| ServiceError::Persistence)?;
    let object = data.as_object_mut().ok_or(ServiceError::InvalidRequest)?;
    object.insert("id".into(), json!(persisted_id));
    object.insert("resourceId".into(), json!(persisted_id));
    object.insert("resourceType".into(), json!(resource_type));
    object.insert(
        "status".into(),
        json!(command_status(operation.id, payload_object)),
    );
    object.insert("version".into(), json!(version));
    object.insert("updatedAt".into(), json!(occurred_text));
    object.insert("updatedBy".into(), json!(actor_id));
    Ok(PreparedCommand {
        canonical_payload,
        payload: data,
        resource_type,
        persisted_id,
        version,
        status_code: operation.success_status,
        occurred_at,
        occurred_text,
    })
}

async fn schedule_rule_activation(
    operation: &OperationSpec,
    payload: &Map<String, Value>,
    actor_id: Uuid,
    request_id: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if operation.id != "scheduleRuleActivation" {
        return Ok(());
    }
    let rule_version_id =
        uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let effective_at =
        timestamp_value(payload, "effectiveAt")?.ok_or(ServiceError::InvalidRequest)?;
    let dedupe = format!("rule-activation:{rule_version_id}:{request_id}");
    enqueue_runtime_job(
        transaction,
        "RULE_ACTIVATION",
        "scheduler",
        json!({"actorId":actor_id,"requestId":request_id,"ruleVersionId":rule_version_id}),
        dedupe.clone(),
    )
    .await?;
    sqlx::query(
        "UPDATE ops.jobs SET run_after=$2 WHERE job_type='RULE_ACTIVATION' AND dedupe_key=$1",
    )
    .bind(dedupe)
    .bind(effective_at)
    .execute(&mut **transaction)
    .await
    .map_err(db)?;
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "command finalization carries transaction-bound audit and event context"
)]
async fn finalize_command(
    operation: &OperationSpec,
    payload: &Value,
    actor_id: Uuid,
    session_id: Uuid,
    request_id: Uuid,
    previous_case_state: Option<&str>,
    key: &CommandKey,
    prepared: &mut PreparedCommand,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(Output, Vec<PendingDomainEvent>), ServiceError> {
    let audit_event_id = append_audit_event(
        operation,
        actor_id,
        session_id,
        request_id,
        key,
        prepared,
        transaction,
    )
    .await?;
    let mut receipt_data = json!({"id":prepared.persisted_id,"resourceId":prepared.persisted_id,"resourceVersion":prepared.version,"version":prepared.version,"status":"completed","operationId":operation.id,"requestId":request_id,"aggregateId":prepared.persisted_id.to_string(),"aggregateVersion":prepared.version,"auditEventId":audit_event_id,"acceptedAt":prepared.occurred_text,"data":prepared.payload,"links":[]});
    if operation.id == "triageSignal" {
        let details = triage_signal_details(prepared)?;
        let (reason_digest, receipt_digest) =
            append_triage_receipt_data(&mut receipt_data, &details)?;
        persist_triage_signal(
            prepared,
            &details,
            actor_id,
            request_id,
            audit_event_id,
            &reason_digest,
            &receipt_digest,
            transaction,
        )
        .await?;
    }
    let response = response_for(operation, &receipt_data)?;
    let candidates = event_candidates(
        payload,
        EventCandidateContext {
            operation: operation.id,
            actor_id,
            request_id,
            resource_id: prepared.persisted_id,
            resource_version: prepared.version,
            occurred_at: &prepared.occurred_text,
            previous_case_state,
        },
    )?;
    let pending_domain_events =
        enqueue_command_events(operation, &candidates, prepared, transaction).await?;
    let completed = sqlx::query(
        "UPDATE ops.idempotency_keys SET response_status=$4,response_body=$5,resource_type=$6,resource_id=$7 \
         WHERE scope=$1 AND key_hash=$2 AND request_hash=$3 \
         AND response_status IS NULL AND expires_at>clock_timestamp()",
    )
    .bind(&key.scope)
    .bind(&key.key_hash)
    .bind(&key.request_hash)
    .bind(i32::from(prepared.status_code))
    .bind(&response)
    .bind(prepared.resource_type)
    .bind(prepared.persisted_id.to_string())
    .execute(&mut **transaction)
    .await
    .map_err(db)?
    .rows_affected();
    if completed != 1 {
        return Err(ServiceError::IdempotencyConflict);
    }
    Ok((
        Output {
            status: prepared.status_code,
            media_type: if prepared.status_code == 204 {
                ""
            } else {
                "application/json"
            },
            body: response,
            replay: false,
        },
        pending_domain_events,
    ))
}

fn triage_result(decision: &str) -> Result<&'static str, ServiceError> {
    match decision {
        "dismiss" | "DISMISS" => Ok("DISMISS"),
        "needs_data" | "NEEDS_DATA" => Ok("NEEDS_DATA"),
        "duplicate" | "MARK_DUPLICATE" => Ok("MARK_DUPLICATE"),
        "investigate" | "PROMOTE_TO_CASE" => Ok("PROMOTE_TO_CASE"),
        "link" | "LINK_TO_CASE" => Ok("LINK_TO_CASE"),
        _ => Err(ServiceError::InvalidRequest),
    }
}

include!("command_support.rs");
