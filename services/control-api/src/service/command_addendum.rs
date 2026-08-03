#[derive(sqlx::FromRow)]
struct AddendumCommandRow {
    aggregate_id: Uuid,
    aggregate_version: i64,
    status: String,
    accepted_at: OffsetDateTime,
    response_body: Value,
    receipt_digest: String,
    audit_event_id: Uuid,
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
    let row = sqlx::query_as::<_, AddendumCommandRow>(
        "SELECT aggregate_id,aggregate_version,status,accepted_at,response_body,receipt_digest,audit_event_id,outbox_event_id \
         FROM ops.apply_control_addendum_command($1,$2,$3,$4,$5,$6,$7)",
    )
    .bind(operation.id)
    .bind(&payload)
    .bind(actor_id)
    .bind(session_id)
    .bind(request_id)
    .bind(&key.key_hash)
    .bind(&key.request_hash)
    .fetch_one(&mut *transaction)
    .await
    .map_err(|error| {
        tracing::error!(operation = operation.id, error = %error, "addendum owner command failed");
        db(error)
    })?;
    let _persisted_receipt_metadata = (
        row.aggregate_version,
        &row.status,
        row.accepted_at,
        &row.receipt_digest,
        row.audit_event_id,
        row.outbox_event_id,
    );
    let response = response_for(operation, &row.response_body)?;
    sqlx::query(
        "UPDATE ops.idempotency_keys SET response_status=$3,response_body=$4,resource_type=$5,resource_id=$6 \
         WHERE scope=$1 AND key_hash=$2",
    )
    .bind(&key.scope)
    .bind(&key.key_hash)
    .bind(i32::from(operation.success_status))
    .bind(&response)
    .bind(gurine_api_contracts::addendum::persistence_owner(operation.id).ok_or(ServiceError::Persistence)?)
    .bind(row.aggregate_id.to_string())
    .execute(&mut *transaction)
    .await
    .map_err(db)?;
    transaction.commit().await.map_err(db)?;
    Ok(Output {
        status: operation.success_status,
        media_type: if operation.success_status == 204 { "" } else { "application/json" },
        body: response,
        replay: false,
    })
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
        if let Some(origin) = payload
            .get_mut("origin")
            .and_then(Value::as_object_mut)
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
