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
    .map_err(|error| map_addendum_owner_error(operation.id, error))?;
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
    payload = seal_privacy_correction_plan(operation.id, payload, field_keys)?;
    payload = seal_privacy_request_transition(operation.id, payload, field_keys)?;
    payload = seal_action_request(operation.id, payload, field_keys)?;
    if operation.id == "createResponseRequest"
        && let Some(email) = payload.get("recipientEmail").and_then(Value::as_str)
        && !valid_recipient_email(email)
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(payload)
}

fn seal_privacy_request_transition(
    operation: &str,
    mut payload: Value,
    field_keys: &EnvelopeKeyRing,
) -> Result<Value, ServiceError> {
    if operation != "transitionRetentionRequest" {
        return Ok(payload);
    }
    let transition = payload
        .get("transition")
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)?;
    let transition_receipt_id = Uuid::new_v4();
    let fields: &[(&str, &str, &str, &str)] = match transition {
        "VERIFY_IDENTITY" | "START_REVIEW" | "APPROVE" => {
            &[("reason", "reasonCiphertextBase64", "reasonSha256", "REASON")]
        }
        "EXTEND" => &[
            ("reason", "reasonCiphertextBase64", "reasonSha256", "REASON"),
            (
                "extensionReason",
                "extensionReasonCiphertextBase64",
                "extensionReasonSha256",
                "EXTENSION_REASON",
            ),
        ],
        "REJECT" => &[
            ("reason", "reasonCiphertextBase64", "reasonSha256", "REASON"),
            (
                "rejectionReason",
                "rejectionReasonCiphertextBase64",
                "rejectionReasonSha256",
                "REJECTION_REASON",
            ),
            (
                "appealInstructions",
                "appealInstructionsCiphertextBase64",
                "appealInstructionsSha256",
                "APPEAL_INSTRUCTIONS",
            ),
        ],
        _ => return Err(ServiceError::InvalidRequest),
    };
    let object = payload
        .as_object_mut()
        .ok_or(ServiceError::InvalidRequest)?;
    object.insert(
        "transitionReceiptId".to_owned(),
        json!(transition_receipt_id),
    );
    for &(plaintext_field, ciphertext_field, digest_field, field_kind) in fields {
        let mut plaintext = match object.remove(plaintext_field) {
            Some(Value::String(value)) => value.into_bytes(),
            _ => return Err(ServiceError::InvalidRequest),
        };
        let receipt_id = transition_receipt_id.to_string();
        let ciphertext_result = encrypt(
            "gurine-fe-v1",
            &field_keys.current,
            &[
                "ops.privacy_request_sealed_content_v2",
                "sealed_ciphertext",
                &receipt_id,
                field_kind,
                "1",
            ],
            &plaintext,
        );
        let plaintext_digest = sha256(&plaintext);
        plaintext.fill(0);
        let ciphertext = ciphertext_result.map_err(|_| ServiceError::Persistence)?;
        object.insert(
            ciphertext_field.to_owned(),
            json!(BASE64.encode(ciphertext.as_bytes())),
        );
        object.insert(digest_field.to_owned(), json!(plaintext_digest));
    }
    Ok(payload)
}

include!("command_addendum_errors.rs");

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
    if matches!(
        operation.id,
        "createPrivacyCorrectionPlan" | "submitActionDecision" | "transitionRetentionRequest"
    ) && let Some(object) = payload.as_object_mut()
    {
        object.insert("_actorAssertionJti".to_owned(), json!(claims.jti));
        object.insert(
            "_actorAssuranceLevel".to_owned(),
            json!(claims.assurance_level),
        );
        object.insert(
            "_actorAssertionRequestSha256".to_owned(),
            json!(actor_assertion_request_digest(claims)),
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
        object.insert("_actorRequestKeySha256".to_owned(), json!(key.key_hash));
        if matches!(
            operation.id,
            "createPrivacyCorrectionPlan" | "transitionRetentionRequest"
        ) {
            object.insert(
                "_actorEffectiveCapability".to_owned(),
                json!(operation.capability),
            );
            object.remove("_actorStepUpAtUnix");
        } else {
            object.insert("_actorStepUpAtUnix".to_owned(), json!(claims.step_up_at));
        }
    }
}

#[cfg(test)]
mod actor_binding_tests {
    use super::*;
    use gurine_auth::envelope::{EnvelopeKey, decrypt};

    fn step_up_claims() -> ActorClaims {
        ActorClaims {
            action_digest: Some("a".repeat(64)),
            assurance_level: "STEP_UP".to_owned(),
            aud: "control-api".to_owned(),
            auth_time: 1,
            body_sha256: "b".repeat(64),
            capabilities: vec!["privacy.requests.manage".to_owned()],
            capability_hash: "c".repeat(64),
            content_type: "application/json".to_owned(),
            exp: 20,
            iat: 1,
            idempotency_key_sha256: Some("f".repeat(64)),
            iss: "identity-api".to_owned(),
            jti: "00000000-0000-4000-8000-000000000004".to_owned(),
            method: "POST".to_owned(),
            operation_id: "transitionRetentionRequest".to_owned(),
            path: "/v1/internal/retention-requests/00000000-0000-4000-8000-000000000001:transition"
                .to_owned(),
            query_sha256: "e".repeat(64),
            required_capability: "privacy.requests.manage".to_owned(),
            roles_version: 1,
            sid: "00000000-0000-4000-8000-000000000002".to_owned(),
            step_up_at: Some(1),
            step_up_authorization_id: Some("00000000-0000-4000-8000-000000000003".to_owned()),
            sub: "00000000-0000-4000-8000-000000000004".to_owned(),
            typ: "actor".to_owned(),
            v: 1,
        }
    }

    #[test]
    fn retention_transition_binds_verified_step_up_claims_outside_public_payload() {
        let operation = OperationSpec {
            id: "transitionRetentionRequest",
            api: "control-api",
            method: "POST",
            path: "/v1/internal/retention-requests/{retentionRequestId}:transition",
            auth: "actor-assertion",
            capability: "privacy.requests.manage",
            idempotency_required: true,
            assurance_level: "STEP_UP",
            step_up_required: true,
            operation_kind: "COMMAND",
            success_status: 200,
            media_type: "application/json",
            response_json: "{}",
        };
        let key = CommandKey {
            scope: "control:test:transitionRetentionRequest".to_owned(),
            key_hash: "f".repeat(64),
            request_hash: "0".repeat(64),
        };
        let mut payload = json!({
            "retentionRequestId": "00000000-0000-4000-8000-000000000001",
            "transition": "VERIFY_IDENTITY",
            "_actorAssertionJti": "caller-spoof"
        });

        let claims = step_up_claims();
        let expected_request_digest = actor_assertion_request_digest(&claims);
        bind_actor_assertion_fields(&operation, &claims, &key, &mut payload);

        assert_eq!(
            payload.get("_actorAssertionJti").and_then(Value::as_str),
            Some("00000000-0000-4000-8000-000000000004")
        );
        assert_eq!(
            payload.get("_actorAssuranceLevel").and_then(Value::as_str),
            Some("STEP_UP")
        );
        assert_eq!(
            payload
                .get("_actorAssertionRequestSha256")
                .and_then(Value::as_str),
            Some(expected_request_digest.as_str())
        );
        assert_eq!(
            payload
                .get("_actorRequestKeySha256")
                .and_then(Value::as_str),
            Some(key.key_hash.as_str())
        );
        assert_eq!(
            payload
                .get("_actorIdempotencyKeySha256")
                .and_then(Value::as_str),
            Some(key.key_hash.as_str())
        );
        assert_eq!(
            payload
                .get("_actorStepUpAuthorizationId")
                .and_then(Value::as_str),
            Some("00000000-0000-4000-8000-000000000003")
        );
        assert_eq!(
            payload
                .get("_actorEffectiveCapability")
                .and_then(Value::as_str),
            Some("privacy.requests.manage")
        );
        assert!(payload.get("_actorStepUpAtUnix").is_none());
        let internal_fields = payload
            .as_object()
            .map(|object| {
                object
                    .keys()
                    .filter(|field| field.starts_with("_actor"))
                    .map(String::as_str)
                    .collect::<BTreeSet<_>>()
            })
            .unwrap_or_default();
        assert_eq!(
            internal_fields,
            BTreeSet::from([
                "_actorActionDigest",
                "_actorAssertionJti",
                "_actorAssertionRequestSha256",
                "_actorAssuranceLevel",
                "_actorEffectiveCapability",
                "_actorIdempotencyKeySha256",
                "_actorRequestKeySha256",
                "_actorStepUpAuthorizationId",
            ])
        );
    }

    #[test]
    fn action_decision_overwrites_all_owner_required_actor_assertion_bindings() {
        let operation = OperationSpec {
            id: "submitActionDecision",
            api: "control-api",
            method: "POST",
            path: "/v1/internal/action-proposals/{proposalId}:decide",
            auth: "actor-assertion-and-capability",
            capability: "actions.review",
            idempotency_required: true,
            assurance_level: "conditional-by-action-and-decision",
            step_up_required: false,
            operation_kind: "COMMAND",
            success_status: 200,
            media_type: "application/json",
            response_json: "{}",
        };
        let key = CommandKey {
            scope: "control:test:submitActionDecision".to_owned(),
            key_hash: "f".repeat(64),
            request_hash: "0".repeat(64),
        };
        let mut payload = json!({
            "_actorAssertionJti": "caller-spoof",
            "_actorAssuranceLevel": "ACTIVE_SESSION",
            "_actorActionDigest": null,
            "_actorStepUpAuthorizationId": null,
            "_actorIdempotencyKeySha256": "0".repeat(64),
            "_actorRequestKeySha256": "0".repeat(64),
        });

        bind_actor_assertion_fields(&operation, &step_up_claims(), &key, &mut payload);

        for (field, expected) in [
            ("_actorAssertionJti", "00000000-0000-4000-8000-000000000004"),
            ("_actorAssuranceLevel", "STEP_UP"),
            ("_actorActionDigest", &"a".repeat(64)),
            (
                "_actorStepUpAuthorizationId",
                "00000000-0000-4000-8000-000000000003",
            ),
            ("_actorIdempotencyKeySha256", &"f".repeat(64)),
            ("_actorRequestKeySha256", &"f".repeat(64)),
        ] {
            assert_eq!(payload.get(field).and_then(Value::as_str), Some(expected));
        }
    }

    #[test]
    fn retention_transition_seals_free_text_before_database_owner_call() {
        let keys = EnvelopeKeyRing {
            current: EnvelopeKey::new([7_u8; 32]),
            previous: None,
        };
        let payload = json!({
            "retentionRequestId": "00000000-0000-4000-8000-000000000001",
            "expectedDecisionVersion": 2,
            "transition": "REJECT",
            "reasonCode": "LEGAL_REVIEW",
            "reason": "운영 검토 사유",
            "rejectionReasonCode": "PROOF_INVALID",
            "rejectionReason": "신원 증빙 불일치",
            "appealInstructions": "새 증빙과 함께 이의 신청"
        });

        let sealed = seal_privacy_request_transition("transitionRetentionRequest", payload, &keys);
        assert!(sealed.is_ok());
        let Ok(sealed) = sealed else {
            return;
        };

        for field in ["reason", "rejectionReason", "appealInstructions"] {
            assert!(sealed.get(field).is_none());
        }
        let sealed_fields = sealed
            .as_object()
            .map(|object| object.keys().map(String::as_str).collect::<BTreeSet<_>>())
            .unwrap_or_default();
        assert_eq!(
            sealed_fields,
            BTreeSet::from([
                "appealInstructionsCiphertextBase64",
                "appealInstructionsSha256",
                "expectedDecisionVersion",
                "reasonCiphertextBase64",
                "reasonCode",
                "reasonSha256",
                "rejectionReasonCiphertextBase64",
                "rejectionReasonCode",
                "rejectionReasonSha256",
                "retentionRequestId",
                "transition",
                "transitionReceiptId",
            ])
        );
        let receipt_id = sealed.get("transitionReceiptId").and_then(Value::as_str);
        assert!(receipt_id.is_some());
        let Some(receipt_id) = receipt_id else {
            return;
        };
        let ciphertext_base64 = sealed
            .get("rejectionReasonCiphertextBase64")
            .and_then(Value::as_str);
        assert!(ciphertext_base64.is_some());
        let Some(ciphertext_base64) = ciphertext_base64 else {
            return;
        };
        let ciphertext = BASE64.decode(ciphertext_base64);
        assert!(ciphertext.is_ok());
        let Ok(ciphertext) = ciphertext else {
            return;
        };
        let ciphertext = std::str::from_utf8(&ciphertext);
        assert!(ciphertext.is_ok());
        let Ok(ciphertext) = ciphertext else {
            return;
        };
        let plaintext = decrypt(
            "gurine-fe-v1",
            &keys,
            &[
                "ops.privacy_request_sealed_content_v2",
                "sealed_ciphertext",
                receipt_id,
                "REJECTION_REASON",
                "1",
            ],
            ciphertext,
        );
        assert!(plaintext.is_ok());
        let Ok(plaintext) = plaintext else {
            return;
        };
        assert_eq!(plaintext, "신원 증빙 불일치".as_bytes());
        assert_eq!(
            sealed.get("rejectionReasonSha256").and_then(Value::as_str),
            Some(sha256("신원 증빙 불일치".as_bytes()).as_str())
        );
    }
}

#[cfg(test)]
#[path = "command_addendum_error_tests.rs"]
mod command_addendum_error_tests;
#[cfg(test)]
#[path = "command_addendum_normalization_tests.rs"]
mod command_addendum_normalization_tests;

fn normalize_owner_payload(operation: &str, mut payload: Value) -> Value {
    let is_economics_import = payload
        .get("draft")
        .and_then(Value::as_object)
        .and_then(|draft| draft.get("kind"))
        .and_then(Value::as_str)
        == Some(ECONOMICS_IMPORT_ACTION_KIND);
    if matches!(operation, "createActionProposal" | "updateActionDraft")
        && !is_economics_import
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
