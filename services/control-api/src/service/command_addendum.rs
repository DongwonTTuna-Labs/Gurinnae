#[derive(sqlx::FromRow)]
struct AddendumCommandRow {
    aggregate_id: Option<Uuid>,
    aggregate_version: Option<i64>,
    status: Option<String>,
    accepted_at: Option<OffsetDateTime>,
    response_body: Option<Value>,
    receipt_digest: Option<String>,
    audit_event_id: Option<Uuid>,
    outbox_event_id: Option<Uuid>,
}

async fn addendum_command(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    claims: &ActorClaims,
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    request_id: Uuid,
    payload: Value,
) -> Result<Output, ServiceError> {
    let actor_id = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let session_id = Uuid::parse_str(&claims.sid).map_err(|_| ServiceError::InvalidRequest)?;
    let (mut transaction, key, replay) =
        begin_idempotency(pool, operation, request, body, claims).await?;
    if let Some(response) = replay {
        transaction.commit().await.map_err(db)?;
        return Ok(response);
    }
    let mut payload = prepare_addendum_payload(operation, request, field_keys, payload)?;
    bind_actor_assertion_fields(operation, claims, &key, &mut payload);
    let row = sqlx::query_as!(
        AddendumCommandRow,
        "SELECT aggregate_id,aggregate_version,status,accepted_at,response_body,receipt_digest,audit_event_id,outbox_event_id \
         FROM ops.apply_control_addendum_command($1,$2,$3,$4,$5,$6,$7)",
        operation.id,
        &payload,
        actor_id,
        session_id,
        request_id,
        &key.key_hash,
        &key.request_hash,
    )
    .fetch_one(&mut *transaction)
    .await
    .map_err(|error| {
        tracing::error!(operation = operation.id, error = %error, "addendum owner command failed");
        db(error)
    })?;
    let aggregate_id = required_sqlx_value(row.aggregate_id)?;
    let aggregate_version = required_sqlx_value(row.aggregate_version)?;
    let status = required_sqlx_value(row.status)?;
    let accepted_at = required_sqlx_value(row.accepted_at)?;
    let response_body = required_sqlx_value(row.response_body)?;
    let receipt_digest = required_sqlx_value(row.receipt_digest)?;
    let audit_event_id = required_sqlx_value(row.audit_event_id)?;
    let _persisted_receipt_metadata = (
        aggregate_version,
        &status,
        accepted_at,
        &receipt_digest,
        audit_event_id,
        row.outbox_event_id,
    );
    let response = response_for(operation, &response_body)?;
    sqlx::query!(
        "UPDATE ops.idempotency_keys SET response_status=$3,response_body=$4,resource_type=$5,resource_id=$6 \
         WHERE scope=$1 AND key_hash=$2",
        &key.scope,
        &key.key_hash,
        i32::from(operation.success_status),
        &response,
        gurine_api_contracts::addendum::persistence_owner(operation.id)
            .ok_or(ServiceError::Persistence)?,
        aggregate_id.to_string(),
    )
    .execute(&mut *transaction)
    .await
    .map_err(db)?;
    transaction.commit().await.map_err(db)?;
    Ok(Output {
        status: operation.success_status,
        media_type: if operation.success_status == 204 {
            ""
        } else {
            "application/json"
        },
        body: response,
        replay: false,
    })
}

fn prepare_addendum_payload(
    operation: &OperationSpec,
    request: &HttpRequest,
    field_keys: &EnvelopeKeyRing,
    payload: Value,
) -> Result<Value, ServiceError> {
    let payload_object = payload.as_object().ok_or(ServiceError::InvalidRequest)?;
    let mut payload = Value::Object(command_parameters(request, payload_object));
    payload = normalize_owner_payload(operation.id, payload);
    payload = seal_action_request(operation.id, payload, field_keys)?;
    if operation.id == "createResponseRequest"
        && let Some(email) = payload.get("recipientEmail").and_then(Value::as_str)
        && !valid_recipient_email(email)
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(payload)
}

fn bind_actor_assertion_fields(
    operation: &OperationSpec,
    claims: &ActorClaims,
    key: &CommandKey,
    payload: &mut Value,
) {
    // Bind the owner assertion-attempt record to the actor assertion already
    // verified by the HTTP boundary; callers cannot supply these fields.
    if operation.id == "decideJourneyHandoff"
        && let Some(object) = payload.as_object_mut()
    {
        object.insert("assertionJti".to_owned(), json!(claims.jti));
        object.insert("issuer".to_owned(), json!(claims.iss));
        object.insert("audience".to_owned(), json!(claims.aud));
        object.insert("expiresAtUnix".to_owned(), json!(claims.exp));
    }
    // The HTTP boundary has already verified these Actor Assertion claims
    // against the exact method/path/query/body/content type/operation,
    // capability and Idempotency-Key.  Keep them outside the public request
    // schema and pass them to the database owner so a STEP_UP decision cannot
    // substitute caller-authored body fields for the signed assertion.
    if operation.id == "submitActionDecision"
        && let Some(object) = payload.as_object_mut()
    {
        object.insert("_actorAssertionJti".to_owned(), json!(claims.jti));
        object.insert(
            "_actorAssuranceLevel".to_owned(),
            json!(claims.assurance_level),
        );
        object.insert("_actorActionDigest".to_owned(), json!(claims.action_digest));
        object.insert(
            "_actorStepUpAuthorizationId".to_owned(),
            json!(claims.step_up_authorization_id),
        );
        object.insert(
            "_actorIdempotencyKeySha256".to_owned(),
            json!(claims.idempotency_key_sha256),
        );
        object.insert("_actorStepUpAtUnix".to_owned(), json!(claims.step_up_at));
        object.insert("_actorRequestKeySha256".to_owned(), json!(key.key_hash));
    }
}

fn normalize_owner_payload(operation: &str, mut payload: Value) -> Value {
    if operation == "createActionProposal"
        && let Some(target) = payload
            .get_mut("draft")
            .and_then(Value::as_object_mut)
            .and_then(|draft| draft.get_mut("target"))
            .and_then(Value::as_object_mut)
    {
        if let Some(value) = target.remove("targetType") {
            target.entry("type").or_insert(value);
        }
        if let Some(value) = target.remove("targetId") {
            target.entry("id").or_insert(value);
        }
        if let Some(value) = target.remove("expectedVersion") {
            target.entry("version").or_insert(value);
        }

        // The public contract calls this field `actorId`; the SECURITY DEFINER
        // owner function consumes the canonical `origin.id` binding.
        if let Some(origin) = payload.get_mut("origin").and_then(Value::as_object_mut)
            && let Some(value) = origin.remove("actorId")
        {
            origin.entry("id").or_insert(value);
        }
    }
    if operation == "cancelActionExecution"
        && !payload.get("reasonCode").is_some_and(Value::is_string)
    {
        payload["reasonCode"] = json!("OTHER");
    }
    if matches!(operation, "declareConflict" | "withdrawConflict")
        && let Some(target_object) = payload.get("target").and_then(Value::as_object)
    {
        let flattened = ["targetType", "targetId", "targetVersion", "targetDigest"]
            .iter()
            .filter_map(|key| target_object.get(*key).cloned().map(|value| (*key, value)))
            .collect::<Vec<_>>();
        for (key, value) in flattened {
            payload[key] = value;
        }
    }
    payload
}
