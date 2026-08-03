fn seal_privacy_correction_plan(
    operation: &str,
    mut payload: Value,
    field_keys: &EnvelopeKeyRing,
) -> Result<Value, ServiceError> {
    if operation != "createPrivacyCorrectionPlan" {
        return Ok(payload);
    }
    let correction_plan_id = Uuid::new_v4();
    let correction_plan_id_text = correction_plan_id.to_string();
    let object = payload
        .as_object_mut()
        .ok_or(ServiceError::InvalidRequest)?;
    normalize_correction_evidence_ids(object)?;
    let mut plaintext = match object.remove("requestedValue") {
        Some(Value::String(value)) => value.into_bytes(),
        _ => return Err(ServiceError::InvalidRequest),
    };
    let ciphertext_result = encrypt(
        "gurine-fe-v1",
        &field_keys.current,
        &[
            "ops.privacy_correction_plans_v1",
            "requested_value_ciphertext",
            &correction_plan_id_text,
            "privacy-correction-requested-value",
            "1",
        ],
        &plaintext,
    );
    let plaintext_digest = sha256(&plaintext);
    plaintext.fill(0);
    let ciphertext = ciphertext_result.map_err(|_| ServiceError::Persistence)?;
    object.insert("_correctionPlanId".to_owned(), json!(correction_plan_id));
    object.insert(
        "requestedValueCiphertextBase64".to_owned(),
        json!(BASE64.encode(ciphertext.as_bytes())),
    );
    object.insert("requestedValueSha256".to_owned(), json!(plaintext_digest));
    Ok(payload)
}

fn normalize_correction_evidence_ids(object: &mut Map<String, Value>) -> Result<(), ServiceError> {
    let values = object
        .get("evidenceIds")
        .and_then(Value::as_array)
        .ok_or(ServiceError::InvalidRequest)?;
    let mut ids = values
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
                .ok_or(ServiceError::InvalidRequest)
        })
        .collect::<Result<Vec<_>, _>>()?;
    ids.sort_unstable();
    if ids.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(ServiceError::InvalidRequest);
    }
    object.insert("evidenceIds".to_owned(), json!(ids));
    Ok(())
}

fn validate_privacy_correction_plan_replay(
    object: &Map<String, Value>,
) -> Result<(), ServiceError> {
    const EXPECTED_KEYS: &[&str] = &[
        "operationId",
        "requestId",
        "status",
        "aggregateId",
        "aggregateVersion",
        "auditEventId",
        "receiptToken",
        "acceptedAt",
        "links",
        "correctionPlanId",
        "retentionRequestId",
        "planVersion",
    ];
    if object.len() != EXPECTED_KEYS.len()
        || EXPECTED_KEYS.iter().any(|key| !object.contains_key(*key))
        || object.get("operationId").and_then(Value::as_str) != Some("createPrivacyCorrectionPlan")
        || object.get("status").and_then(Value::as_str) != Some("completed")
        || !object.get("links").is_some_and(Value::is_array)
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    validate_replay_links(object)?;
    for key in [
        "requestId",
        "aggregateId",
        "auditEventId",
        "correctionPlanId",
        "retentionRequestId",
    ] {
        replay_uuid(object, key)?;
    }
    replay_timestamp(object, "acceptedAt")?;
    let plan_version = object
        .get("planVersion")
        .and_then(Value::as_i64)
        .filter(|version| *version >= 1)
        .ok_or(ServiceError::IdempotencyConflict)?;
    if object.get("aggregateId") != object.get("correctionPlanId")
        || object.get("aggregateVersion").and_then(Value::as_i64) != Some(plan_version)
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    Ok(())
}

#[cfg(test)]
mod privacy_correction_plan_tests {
    use super::*;
    use gurine_auth::envelope::{EnvelopeKey, decrypt};

    fn correction_claims() -> ActorClaims {
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
            jti: "10000000-0000-4000-8000-000000000004".to_owned(),
            method: "POST".to_owned(),
            operation_id: "createPrivacyCorrectionPlan".to_owned(),
            path: "/v1/internal/commands/create-privacy-correction-plan".to_owned(),
            query_sha256: "e".repeat(64),
            required_capability: "privacy.requests.manage".to_owned(),
            roles_version: 1,
            sid: "10000000-0000-4000-8000-000000000002".to_owned(),
            step_up_at: Some(1),
            step_up_authorization_id: Some("10000000-0000-4000-8000-000000000003".to_owned()),
            sub: "10000000-0000-4000-8000-000000000004".to_owned(),
            typ: "actor".to_owned(),
            v: 1,
        }
    }

    #[test]
    fn requested_value_is_sealed_with_the_fixed_plan_bound_aad() {
        let keys = EnvelopeKeyRing {
            current: EnvelopeKey::new([9_u8; 32]),
            previous: None,
        };
        let payload = json!({
            "retentionRequestId":"10000000-0000-4000-8000-000000000001",
            "expectedDecisionVersion":2,
            "targetObjectType":"RESPONSE",
            "targetObjectId":"10000000-0000-4000-8000-000000000002",
            "fieldPath":"/partyName",
            "currentValueDigest":"a".repeat(64),
            "requestedValue":"정정된 표시 이름",
            "evidenceIds":["10000000-0000-4000-8000-000000000003"],
            "reason":"증거와 일치하도록 정정 계획을 기록함"
        });

        let sealed = seal_privacy_correction_plan("createPrivacyCorrectionPlan", payload, &keys)
            .unwrap_or_else(|error| panic!("seal correction plan: {error}"));
        assert!(sealed.get("requestedValue").is_none());
        let plan_id = sealed
            .get("_correctionPlanId")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .filter(|value| !value.is_nil());
        assert!(plan_id.is_some());
        let Some(plan_id) = plan_id else {
            return;
        };
        let ciphertext = sealed
            .get("requestedValueCiphertextBase64")
            .and_then(Value::as_str)
            .and_then(|value| BASE64.decode(value).ok())
            .and_then(|value| String::from_utf8(value).ok());
        assert!(ciphertext.is_some());
        let Some(ciphertext) = ciphertext else {
            return;
        };
        let plan_id_text = plan_id.to_string();
        let plaintext = decrypt(
            "gurine-fe-v1",
            &keys,
            &[
                "ops.privacy_correction_plans_v1",
                "requested_value_ciphertext",
                &plan_id_text,
                "privacy-correction-requested-value",
                "1",
            ],
            &ciphertext,
        )
        .unwrap_or_else(|error| panic!("decrypt correction plan: {error}"));
        assert_eq!(plaintext, "정정된 표시 이름".as_bytes());
        assert_eq!(
            sealed.get("requestedValueSha256").and_then(Value::as_str),
            Some(sha256("정정된 표시 이름".as_bytes()).as_str())
        );
    }

    #[test]
    fn unrelated_operations_are_not_rewritten() {
        let keys = EnvelopeKeyRing {
            current: EnvelopeKey::new([9_u8; 32]),
            previous: None,
        };
        let payload = json!({"requestedValue":"unchanged"});
        let unchanged =
            seal_privacy_correction_plan("transitionRetentionRequest", payload.clone(), &keys)
                .unwrap_or_else(|error| panic!("unrelated operation: {error}"));
        assert_eq!(unchanged, payload);
    }

    #[test]
    fn owner_evidence_set_is_uuid_canonical_and_sorted() {
        let keys = EnvelopeKeyRing {
            current: EnvelopeKey::new([9_u8; 32]),
            previous: None,
        };
        let payload = json!({
            "requestedValue":"정정값",
            "evidenceIds":[
                "20000000-0000-4000-8000-000000000002",
                "10000000-0000-4000-8000-000000000001"
            ]
        });
        let sealed = seal_privacy_correction_plan("createPrivacyCorrectionPlan", payload, &keys)
            .unwrap_or_else(|error| panic!("seal correction plan: {error}"));
        assert_eq!(
            sealed.get("evidenceIds"),
            Some(&json!([
                "10000000-0000-4000-8000-000000000001",
                "20000000-0000-4000-8000-000000000002"
            ]))
        );
    }

    #[test]
    fn owner_payload_binds_exact_step_up_actor_fields() {
        let operation = OperationSpec {
            id: "createPrivacyCorrectionPlan",
            api: "control-api",
            method: "POST",
            path: "/v1/internal/commands/create-privacy-correction-plan",
            auth: "actor-assertion-and-capability",
            capability: "privacy.requests.manage",
            idempotency_required: true,
            assurance_level: "STEP_UP",
            step_up_required: true,
            operation_kind: "COMMAND",
            success_status: 201,
            media_type: "application/json",
            response_json: "{}",
        };
        let key = CommandKey {
            scope: "control:test:createPrivacyCorrectionPlan".to_owned(),
            key_hash: "f".repeat(64),
            request_hash: "0".repeat(64),
        };
        let claims = correction_claims();
        let expected_request_digest = actor_assertion_request_digest(&claims);
        let keys = EnvelopeKeyRing {
            current: EnvelopeKey::new([9_u8; 32]),
            previous: None,
        };
        let payload = json!({
            "retentionRequestId":"10000000-0000-4000-8000-000000000001",
            "expectedDecisionVersion":2,
            "targetObjectType":"RESPONSE",
            "targetObjectId":"10000000-0000-4000-8000-000000000002",
            "fieldPath":"/partyName",
            "currentValueDigest":"a".repeat(64),
            "requestedValue":"정정된 표시 이름",
            "evidenceIds":["10000000-0000-4000-8000-000000000003"],
            "reason":"증거와 일치하도록 정정 계획을 기록함"
        });
        let mut payload = seal_privacy_correction_plan(operation.id, payload, &keys)
            .unwrap_or_else(|error| panic!("seal correction plan: {error}"));
        bind_actor_assertion_fields(&operation, &claims, &key, &mut payload);
        let owner_fields = payload
            .as_object()
            .map(|object| object.keys().map(String::as_str).collect::<BTreeSet<_>>())
            .unwrap_or_default();
        assert_eq!(
            owner_fields,
            BTreeSet::from([
                "_correctionPlanId",
                "_actorActionDigest",
                "_actorAssertionJti",
                "_actorAssertionRequestSha256",
                "_actorAssuranceLevel",
                "_actorEffectiveCapability",
                "_actorIdempotencyKeySha256",
                "_actorRequestKeySha256",
                "_actorStepUpAuthorizationId",
                "currentValueDigest",
                "evidenceIds",
                "expectedDecisionVersion",
                "fieldPath",
                "reason",
                "requestedValueCiphertextBase64",
                "requestedValueSha256",
                "retentionRequestId",
                "targetObjectId",
                "targetObjectType",
            ])
        );
        assert_eq!(
            payload.get("_actorAssertionJti").and_then(Value::as_str),
            Some("10000000-0000-4000-8000-000000000004")
        );
        assert_eq!(
            payload
                .get("_actorAssertionRequestSha256")
                .and_then(Value::as_str),
            Some(expected_request_digest.as_str())
        );
    }

    #[test]
    fn replay_receipt_is_exact_and_plan_bound() {
        let receipt = json!({
            "operationId":"createPrivacyCorrectionPlan",
            "requestId":"10000000-0000-4000-8000-000000000001",
            "status":"completed",
            "aggregateId":"10000000-0000-4000-8000-000000000002",
            "aggregateVersion":3,
            "auditEventId":"10000000-0000-4000-8000-000000000003",
            "receiptToken":"a".repeat(64),
            "acceptedAt":"2026-08-01T00:00:00Z",
            "links":[],
            "correctionPlanId":"10000000-0000-4000-8000-000000000002",
            "retentionRequestId":"10000000-0000-4000-8000-000000000004",
            "planVersion":3
        });
        let object = receipt.as_object().cloned().unwrap_or_default();
        assert!(validate_privacy_correction_plan_replay(&object).is_ok());

        let mut mismatched = object.clone();
        mismatched.insert("planVersion".to_owned(), json!(4));
        assert!(validate_privacy_correction_plan_replay(&mismatched).is_err());

        let mut non_owner_status = object.clone();
        non_owner_status.insert("status".to_owned(), json!("accepted"));
        assert!(validate_privacy_correction_plan_replay(&non_owner_status).is_err());

        let mut leaked = object;
        leaked.insert("requestedValue".to_owned(), json!("plaintext"));
        assert!(validate_privacy_correction_plan_replay(&leaked).is_err());

        let malformed_link = json!({
            "operationId":"createPrivacyCorrectionPlan",
            "requestId":"10000000-0000-4000-8000-000000000001",
            "status":"completed",
            "aggregateId":"10000000-0000-4000-8000-000000000002",
            "aggregateVersion":3,
            "auditEventId":"10000000-0000-4000-8000-000000000003",
            "receiptToken":"a".repeat(64),
            "acceptedAt":"2026-08-01T00:00:00Z",
            "links":[{"rel":"self","href":"\n"}],
            "correctionPlanId":"10000000-0000-4000-8000-000000000002",
            "retentionRequestId":"10000000-0000-4000-8000-000000000004",
            "planVersion":3
        });
        let malformed_link = malformed_link.as_object().cloned().unwrap_or_default();
        assert!(validate_privacy_correction_plan_replay(&malformed_link).is_err());
    }
}
