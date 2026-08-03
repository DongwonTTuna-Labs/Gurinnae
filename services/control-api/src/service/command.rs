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
    let payload = validated_command_payload(operation.id, body)?;
    let (payload, idempotency_body) = normalized_command_input(operation.id, payload, body)?;
    let payload_object = payload.as_object().ok_or(ServiceError::InvalidRequest)?;
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
    let (actor_id, session_id) = command_actor_ids(claims)?;
    let (mut transaction, key, replay) =
        begin_idempotency(pool, operation, request, idempotency_body.as_ref(), claims).await?;
    if let Some(response) = replay {
        transaction.commit().await.map_err(db)?;
        return Ok(response);
    }
    let previous_case_state =
        validate_case_context(operation.id, payload_object, claims, &mut transaction).await?;
    let mut prepared = prepare_command(
        operation,
        request,
        &payload,
        payload_object,
        actor_id,
        &mut transaction,
    )
    .await?;
    bind_editorial_owner_authority(
        operation.id,
        claims,
        request_id,
        &key,
        &mut prepared.canonical_payload,
    );
    let command_effect = domains::apply_command(
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
    prepared.apply_effect(command_effect)?;
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

include!("command_addendum.rs");
include!("command_privacy_correction.rs");
include!("command_runtime.rs");
include!("command_authority_replay.rs");

fn command_actor_ids(claims: &ActorClaims) -> Result<(Uuid, Uuid), ServiceError> {
    let actor_id = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let session_id = Uuid::parse_str(&claims.sid).map_err(|_| ServiceError::InvalidRequest)?;
    Ok((actor_id, session_id))
}

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
            next_submission_session: None,
        })
        .map_err(|_| ServiceError::InvalidRequest)?,
    };
    let mut transaction = pool.begin().await.map_err(db)?;
    // All control mutations share the same serializable boundary.  Journey
    // owner routines require this before their first statement; applying it
    // here also prevents a caller from accidentally running a mixed-strength
    // transaction through the generic dispatcher.
    sqlx::query!("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *transaction)
        .await
        .map_err(db)?;
    let claimed = sqlx::query!(
        "INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) \
         VALUES($1,$2,$3,clock_timestamp()+interval '24 hours') \
         ON CONFLICT(scope,key_hash) DO UPDATE SET \
         request_hash=EXCLUDED.request_hash,response_status=NULL,response_body=NULL, \
         resource_type=NULL,resource_id=NULL,created_at=clock_timestamp(), \
         expires_at=EXCLUDED.expires_at \
         WHERE ops.idempotency_keys.expires_at<=clock_timestamp()",
        &key.scope,
        &key.key_hash,
        &key.request_hash,
    )
    .execute(&mut *transaction)
    .await
    .map_err(db)?
    .rows_affected();
    let receipt = sqlx::query!(
        "SELECT request_hash,response_status,response_body FROM ops.idempotency_keys \
         WHERE scope=$1 AND key_hash=$2 AND expires_at>clock_timestamp() FOR UPDATE",
        &key.scope,
        &key.key_hash,
    )
    .fetch_optional(&mut *transaction)
    .await
    .map_err(db)?
    .ok_or(ServiceError::IdempotencyConflict)?;
    if receipt.request_hash.trim() != key.request_hash {
        return Err(ServiceError::IdempotencyConflict);
    }
    let replay = if claimed == 0 {
        replay_output(operation.id, receipt.response_status, receipt.response_body)?
            .ok_or(ServiceError::IdempotencyConflict)?
    } else {
        return Ok((transaction, key, None));
    };
    Ok((transaction, key, Some(replay)))
}

fn replay_output(
    operation: &str,
    status: Option<i32>,
    response: Option<Value>,
) -> Result<Option<Output>, ServiceError> {
    let Some(status) = status else {
        return Ok(None);
    };
    let Some(response) = response else {
        return Ok(None);
    };
    validate_owner_replay_if_required(operation, &response)?;
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
    let state = sqlx::query_scalar!(
        "SELECT investigation_state::text FROM editorial.cases WHERE id=$1 FOR UPDATE",
        case_id,
    )
    .fetch_optional(&mut **transaction)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    required_sqlx_value(state).map(Some)
}

async fn validate_case_context(
    operation: &str,
    payload: &Map<String, Value>,
    claims: &ActorClaims,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Option<String>, ServiceError> {
    let previous_state = previous_case_state(operation, payload, transaction).await?;
    validate_transition_case(operation, payload, claims, transaction).await?;
    Ok(previous_state)
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
    owner_receipt: Option<OwnerCommandReceipt>,
}

impl PreparedCommand {
    fn apply_effect(&mut self, effect: CommandEffect) -> Result<(), ServiceError> {
        let CommandEffect {
            fields,
            owner_receipt,
            owner_replaces_aggregate_id,
        } = effect;
        let payload = self
            .payload
            .as_object_mut()
            .ok_or(ServiceError::Persistence)?;
        for (key, value) in fields {
            match payload.get(&key) {
                Some(existing) if existing == &value => {}
                Some(_) => return Err(ServiceError::Persistence),
                None => {
                    payload.insert(key, value);
                }
            }
        }
        if (self.owner_receipt.is_some() && owner_receipt.is_some())
            || (owner_replaces_aggregate_id && owner_receipt.is_none())
        {
            return Err(ServiceError::Persistence);
        }
        if let Some(receipt) = owner_receipt {
            if (receipt.aggregate_id != self.persisted_id && !owner_replaces_aggregate_id)
                || receipt.aggregate_version < 1
                || receipt.audit_event_id.is_nil()
                || !is_sha256(&receipt.receipt_digest)
                || receipt.outbox_event_ids.len() != receipt.expected_outbox_count
                || receipt.outbox_event_ids.iter().any(Uuid::is_nil)
                || OffsetDateTime::parse(&receipt.accepted_at, &Rfc3339).is_err()
            {
                return Err(ServiceError::Persistence);
            }
            if owner_replaces_aggregate_id {
                self.persisted_id = receipt.aggregate_id;
                payload.insert("id".to_owned(), json!(receipt.aggregate_id));
                payload.insert("resourceId".to_owned(), json!(receipt.aggregate_id));
            }
            self.version = receipt.aggregate_version;
            payload.insert("version".to_owned(), json!(receipt.aggregate_version));
            payload.insert(
                "resourceVersion".to_owned(),
                json!(receipt.aggregate_version),
            );
            self.occurred_text.clone_from(&receipt.accepted_at);
            self.owner_receipt = Some(receipt);
        }
        Ok(())
    }
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
        let valid = sqlx::query_scalar!(
            "SELECT EXISTS(SELECT 1 FROM editorial.review_snapshots s \
             JOIN editorial.cases c ON c.id=s.case_id \
             WHERE s.id=$1 AND s.case_id=$2 AND c.current_review_snapshot_id=$1 \
               AND s.unresolved_blockers='[]'::jsonb)",
            snapshot_id,
            case_id,
        )
        .fetch_one(&mut **transaction)
        .await
        .map_err(db)?;
        let valid = required_sqlx_value(valid)?;
        if !valid {
            return Err(ServiceError::InvalidRequest);
        }
    }
    // These specialized handlers own their optimistic update and therefore
    // must validate the expected version and mutate the aggregate atomically.
    // Running the generic guard first would increment the row before the
    // handler sees it, causing a false VERSION_CONFLICT or a double advance.
    let resolved_correction_owner = operation.id == "resolveCorrectionRequest"
        && string_value(payload_object, "resolution") == Some("RESOLVED");
    let canonical_version = if resolved_correction_owner
        || matches!(
            operation.id,
            "attestOrganizationOfficialChannel"
                | "attestEntityMaterialUseClosure"
                | "approveResponseExcerpt"
                | "publishCase"
                | "triageSignal"
                | "acceptAgentSuggestion"
                | "rejectAgentSuggestion"
                | "verifyResponseOrganizationIdentity"
                | "revokeOrganizationOfficialChannel"
                | "classifyEntityPersonhood"
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
    let version = prepared_resource_version(operation.id, canonical_version, expected_version)?;
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
        owner_receipt: None,
    })
}

fn prepared_resource_version(
    _operation: &str,
    canonical_version: Option<i64>,
    expected_version: Option<i64>,
) -> Result<i64, ServiceError> {
    Ok(canonical_version.unwrap_or_else(|| expected_version.map_or(1, |value| value + 1)))
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
    sqlx::query!(
        "UPDATE ops.jobs SET run_after=$2 WHERE job_type='RULE_ACTIVATION' AND dedupe_key=$1",
        dedupe,
        effective_at,
    )
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
    let owner_managed = owner_managed_request(operation.id, payload)?;
    let audit_event_id = command_audit_event_id(
        owner_managed,
        operation,
        actor_id,
        session_id,
        request_id,
        key,
        prepared,
        transaction,
    )
    .await?;
    let mut receipt_data = command_receipt_data(operation, request_id, audit_event_id, prepared)?;
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
    let pending_domain_events = collect_pending_domain_events(
        owner_managed,
        operation,
        payload,
        actor_id,
        request_id,
        previous_case_state,
        prepared,
        transaction,
    )
    .await?;
    let completed = sqlx::query!(
        "UPDATE ops.idempotency_keys SET response_status=$4,response_body=$5,resource_type=$6,resource_id=$7 \
         WHERE scope=$1 AND key_hash=$2 AND request_hash=$3 \
         AND response_status IS NULL AND expires_at>clock_timestamp()",
        &key.scope,
        &key.key_hash,
        &key.request_hash,
        i32::from(prepared.status_code),
        &response,
        prepared.resource_type,
        prepared.persisted_id.to_string(),
    )
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
