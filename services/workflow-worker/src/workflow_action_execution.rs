use gurine_auth::envelope::{decrypt, encrypt};

#[derive(Debug)]
struct CommunicationAction {
    subject_id: Uuid,
    endpoint_id: Uuid,
    endpoint_version: i64,
    endpoint_digest: String,
    channel: String,
    communication_class: String,
    purpose: String,
    locale: String,
    template_id: String,
    template_revision: String,
    subject: String,
    body: String,
    citations: Value,
}

#[derive(Debug)]
struct ApprovedAction {
    proposal_id: Uuid,
    proposal_version: i64,
    payload: Value,
    action: CommunicationAction,
}

#[derive(Debug)]
struct EncryptedRendering {
    id: Uuid,
    bytes: Vec<u8>,
    sha256: String,
    ciphertext: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ApprovedExecutionKind {
    Communication,
    Hypothesis,
}

#[derive(Debug)]
struct ApprovedExecution {
    execution_id: Uuid,
    generation: i64,
    event_payload: Value,
    kind: ApprovedExecutionKind,
}

async fn execute_approved_action(
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    producer_job_id: Uuid,
    producer_job_lease_token: Uuid,
    producer_job_fencing_token: i64,
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let approved_execution = approved_execution(payload, aggregate_id)?;
    if approved_execution.kind == ApprovedExecutionKind::Hypothesis {
        let producer_job = ProducerJobFence {
            id: producer_job_id,
            lease_token: producer_job_lease_token,
            fencing_token: producer_job_fencing_token,
        };
        return execute_approved_hypothesis(
            pool,
            field_keys,
            producer_job,
            &approved_execution,
        )
        .await;
    }
    let ApprovedExecution {
        execution_id,
        generation,
        event_payload,
        kind: ApprovedExecutionKind::Communication,
    } = approved_execution
    else {
        return Err(Failure::Terminal(
            "ACTION_EXECUTOR_UNSUPPORTED",
            "execution kind".to_owned(),
        ));
    };
    let approved =
        load_approved_action(pool, field_keys, execution_id, generation, event_payload).await?;
    let endpoint =
        load_communication_endpoint(pool, execution_id, generation, &approved.action).await?;
    let destination = communication_destination(field_keys, &approved.action, &endpoint)?;
    let rendering = encrypted_rendering(field_keys, execution_id, destination, &approved.action)?;
    let endpoint_snapshot_digest: String = endpoint
        .try_get("endpoint_snapshot_digest")
        .map_err(database)?;
    dispatch_communication(
        pool,
        execution_id,
        generation,
        approved,
        endpoint_snapshot_digest,
        rendering,
    )
    .await
}

fn approved_execution(
    payload: &serde_json::Map<String, Value>,
    aggregate_id: Uuid,
) -> Result<ApprovedExecution, Failure> {
    let execution_id = object_uuid(payload, "executionId")?;
    if execution_id != aggregate_id {
        return Err(Failure::Terminal(
            "ACTION_EXECUTION_EVENT_MISMATCH",
            execution_id.to_string(),
        ));
    }
    let generation = payload
        .get("generation")
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| Failure::Terminal("INVALID_ACTION_EXECUTION", "generation".to_owned()))?;
    let action_kind = payload.get("actionKind").and_then(Value::as_str);
    let target_command = payload.get("targetCommand").and_then(Value::as_str);
    let kind = match (action_kind, target_command) {
        (Some("COMMUNICATION"), Some("private.DispatchCommunicationIntent")) => {
            ApprovedExecutionKind::Communication
        }
        (Some("HYPOTHESIS"), Some("createHypothesis")) => ApprovedExecutionKind::Hypothesis,
        _ => {
            return Err(Failure::Terminal(
                "ACTION_EXECUTOR_UNSUPPORTED",
                format!(
                    "{}:{}",
                    action_kind.unwrap_or("missing"),
                    target_command.unwrap_or("missing")
                ),
            ));
        }
    };
    if kind == ApprovedExecutionKind::Hypothesis && generation != 1 {
        return Err(Failure::Terminal(
            "INVALID_ACTION_EXECUTION",
            "hypothesis generation".to_owned(),
        ));
    }
    Ok(ApprovedExecution {
        execution_id,
        generation,
        event_payload: Value::Object(payload.clone()),
        kind,
    })
}

async fn load_approved_action(
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    execution_id: Uuid,
    generation: i64,
    event_payload: Value,
) -> Result<ApprovedAction, Failure> {
    // The current migration tree, including migration 0030, does not define
    // `ops.load_action_execution_v1`, so SQLx cannot describe this call.
    // Convert it after the authority schema adds the declared procedure and
    // the offline metadata is regenerated.
    let row = sqlx::query("SELECT * FROM ops.load_action_execution_v1($1,$2,$3)")
        .bind(execution_id)
        .bind(generation)
        .bind(&event_payload)
        .fetch_one(pool)
        .await
        .map_err(database)?;
    let proposal_id: Uuid = row.try_get("proposal_id").map_err(database)?;
    let proposal_version: i64 = row.try_get("proposal_version").map_err(database)?;
    let encrypted: Vec<u8> = row.try_get("target_request_encrypted").map_err(database)?;
    let token = std::str::from_utf8(&encrypted).map_err(|_| {
        Failure::Terminal("ACTION_PAYLOAD_DECRYPTION_FAILED", execution_id.to_string())
    })?;
    let proposal_id_text = proposal_id.to_string();
    let plaintext = decrypt(
        "gurine-fe-v1",
        field_keys,
        &[
            "ops.action_proposal_versions",
            "payload_encrypted",
            &proposal_id_text,
            "json",
            "1",
        ],
        token,
    )
    .map_err(|_| Failure::Terminal("ACTION_PAYLOAD_DECRYPTION_FAILED", execution_id.to_string()))?;
    let action_payload: Value = serde_json::from_slice(&plaintext)
        .map_err(|_| Failure::Terminal("ACTION_PAYLOAD_INVALID", execution_id.to_string()))?;
    let action = communication_action(&action_payload)?;
    Ok(ApprovedAction {
        proposal_id,
        proposal_version,
        payload: action_payload,
        action,
    })
}

async fn load_communication_endpoint(
    pool: &PgPool,
    execution_id: Uuid,
    generation: i64,
    action: &CommunicationAction,
) -> Result<sqlx::postgres::PgRow, Failure> {
    // The current migration tree, including migration 0030, does not define
    // `ops.load_action_communication_endpoint_v1`, so SQLx cannot describe
    // this call. Convert it after the authority schema adds the declared
    // procedure and the offline metadata is regenerated.
    sqlx::query(
        "SELECT * FROM ops.load_action_communication_endpoint_v1($1,$2,$3,$4,$5,$6::char(64),$7)",
    )
    .bind(execution_id)
    .bind(generation)
    .bind(action.subject_id)
    .bind(action.endpoint_id)
    .bind(action.endpoint_version)
    .bind(&action.endpoint_digest)
    .bind(&action.channel)
    .fetch_one(pool)
    .await
    .map_err(database)
}

fn communication_destination(
    field_keys: &EnvelopeKeyRing,
    action: &CommunicationAction,
    endpoint: &sqlx::postgres::PgRow,
) -> Result<String, Failure> {
    let endpoint_ciphertext: Vec<u8> = endpoint.try_get("endpoint_ciphertext").map_err(database)?;
    let endpoint_token = std::str::from_utf8(&endpoint_ciphertext).map_err(|_| {
        Failure::Terminal(
            "COMMUNICATION_ENDPOINT_DECRYPTION_FAILED",
            action.endpoint_id.to_string(),
        )
    })?;
    let endpoint_id_text = action.endpoint_id.to_string();
    let endpoint_plaintext = decrypt(
        "gurine-fe-v1",
        field_keys,
        &[
            "intake.communication_endpoints",
            "endpoint_ciphertext",
            &endpoint_id_text,
            endpoint_logical_type(&action.channel),
            "1",
        ],
        endpoint_token,
    )
    .map_err(|_| {
        Failure::Terminal(
            "COMMUNICATION_ENDPOINT_DECRYPTION_FAILED",
            action.endpoint_id.to_string(),
        )
    })?;
    let destination = String::from_utf8(endpoint_plaintext).map_err(|_| {
        Failure::Terminal(
            "COMMUNICATION_ENDPOINT_INVALID",
            action.endpoint_id.to_string(),
        )
    })?;
    if destination.trim().is_empty() || destination.len() > 16_384 {
        return Err(Failure::Terminal(
            "COMMUNICATION_ENDPOINT_INVALID",
            action.endpoint_id.to_string(),
        ));
    }
    Ok(destination)
}

fn encrypted_rendering(
    field_keys: &EnvelopeKeyRing,
    execution_id: Uuid,
    destination: String,
    action: &CommunicationAction,
) -> Result<EncryptedRendering, Failure> {
    let rendering_id = Uuid::new_v4();
    let rendered = json!({
        "to": destination,
        "subject": action.subject,
        "textBody": action.body,
        "htmlBody": "",
        "citations": action.citations,
    });
    let rendered_bytes = serde_json::to_vec(&rendered).map_err(|_| {
        Failure::Terminal("COMMUNICATION_RENDERING_INVALID", execution_id.to_string())
    })?;
    let rendered_sha256 = sha256(&rendered_bytes);
    let rendering_id_text = rendering_id.to_string();
    let rendered_ciphertext = encrypt(
        "gurine-fe-v1",
        &field_keys.current,
        &[
            "ops.communication_renderings",
            "rendered_envelope_ciphertext",
            &rendering_id_text,
            "communication-rendering",
            "1",
        ],
        &rendered_bytes,
    )
    .map(String::into_bytes)
    .map_err(|_| {
        Failure::Terminal(
            "COMMUNICATION_RENDERING_ENCRYPTION_FAILED",
            execution_id.to_string(),
        )
    })?;
    Ok(EncryptedRendering {
        id: rendering_id,
        bytes: rendered_bytes,
        sha256: rendered_sha256,
        ciphertext: rendered_ciphertext,
    })
}

async fn dispatch_communication(
    pool: &PgPool,
    execution_id: Uuid,
    generation: i64,
    approved: ApprovedAction,
    endpoint_snapshot_digest: String,
    rendering: EncryptedRendering,
) -> Result<Value, Failure> {
    let ApprovedAction {
        proposal_id,
        proposal_version,
        payload: action_payload,
        action,
    } = approved;
    let EncryptedRendering {
        id: rendering_id,
        bytes: rendered_bytes,
        sha256: rendered_sha256,
        ciphertext: rendered_ciphertext,
    } = rendering;
    let request_digest =
        sha256(format!("{execution_id}:{generation}:{rendering_id}:{rendered_sha256}").as_bytes());
    // The current migration tree, including migration 0030, does not define
    // `ops.dispatch_approved_communication_intent_v1`, so SQLx cannot describe
    // this call. Convert it after the authority schema adds the declared
    // procedure and the offline metadata is regenerated.
    let receipt: Value = sqlx::query_scalar(
        "SELECT ops.dispatch_approved_communication_intent_v1($1,$2)",
    )
    .bind(json!({
        "executionId": execution_id,
        "generation": generation,
        "proposalId": proposal_id,
        "proposalVersion": proposal_version,
        "renderingId": rendering_id,
        "subjectId": action.subject_id,
        "endpointId": action.endpoint_id,
        "endpointVersion": action.endpoint_version,
        "endpointDigest": action.endpoint_digest,
        "endpointSnapshotDigest": endpoint_snapshot_digest,
        "channel": action.channel,
        "communicationClass": action.communication_class,
        "purpose": action.purpose,
        "locale": action.locale,
        "templateId": action.template_id,
        "templateRevision": action.template_revision,
        "topicScope": {"caseId": action_payload.pointer("/target/id")},
        "semanticPayloadDigest": sha256(action.body.as_bytes()),
        "recipientBindingDigest": sha256(format!("{}:{}:{}:{}", action.subject_id, action.endpoint_id, action.endpoint_version, action.endpoint_digest).as_bytes()),
        "renderedSha256": rendered_sha256,
        "renderedByteLength": rendered_bytes.len(),
        "transportContentType": "application/json; charset=utf-8",
        "requestDigest": request_digest,
    }))
    .bind(rendered_ciphertext)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    Ok(receipt)
}

fn communication_action(payload: &Value) -> Result<CommunicationAction, Failure> {
    if payload.get("kind").and_then(Value::as_str) != Some("COMMUNICATION") {
        return Err(Failure::Terminal(
            "ACTION_PAYLOAD_KIND_MISMATCH",
            "COMMUNICATION".to_owned(),
        ));
    }
    if let Some(proposal) = payload.get("proposal") {
        let binding = proposal.get("recipientBinding").ok_or_else(|| {
            Failure::Terminal("COMMUNICATION_RECIPIENT_BINDING_MISSING", "recipientBinding".to_owned())
        })?;
        let purpose = required_text(proposal, "purpose")?;
        return Ok(CommunicationAction {
            subject_id: required_uuid(binding, "subjectId")?,
            endpoint_id: required_uuid(binding, "endpointId")?,
            endpoint_version: required_positive_i64(binding, "endpointVersion")?,
            endpoint_digest: required_digest(binding, "endpointDigest")?,
            channel: required_text(proposal, "channel")?,
            communication_class: communication_class(&purpose)?.to_owned(),
            purpose,
            locale: proposal
                .get("locale")
                .and_then(Value::as_str)
                .unwrap_or("ko-KR")
                .to_owned(),
            template_id: "agent-approved-draft".to_owned(),
            template_revision: "1".to_owned(),
            subject: proposal
                .get("subject")
                .and_then(Value::as_str)
                .unwrap_or("구린네 근거 확인 요청")
                .to_owned(),
            body: required_text(proposal, "draftText")?,
            citations: proposal.get("citationIds").cloned().unwrap_or_else(|| json!([])),
        });
    }
    let recipients = payload
        .get("recipients")
        .and_then(Value::as_array)
        .filter(|values| values.len() == 1)
        .ok_or_else(|| Failure::Terminal("COMMUNICATION_RECIPIENT_COUNT_UNSUPPORTED", "one exact recipient required".to_owned()))?;
    let recipient = recipients.first().ok_or_else(|| {
        Failure::Terminal("COMMUNICATION_RECIPIENT_MISSING", "recipients".to_owned())
    })?;
    let purpose = required_text(payload, "purpose")?;
    Ok(CommunicationAction {
        subject_id: required_uuid(recipient, "subjectId")?,
        endpoint_id: required_uuid(recipient, "endpointId")?,
        endpoint_version: required_positive_i64(recipient, "endpointVersion")?,
        endpoint_digest: required_digest(recipient, "destinationIdentitySha256")?,
        channel: required_text(payload, "provider")?,
        communication_class: communication_class(&purpose)?.to_owned(),
        purpose,
        locale: required_text(payload, "locale")?,
        template_id: required_text(payload, "templateId")?,
        template_revision: required_positive_i64(payload, "templateRevision")?.to_string(),
        subject: required_text(payload, "subject")?,
        body: required_text(payload, "bodyPlainText")?,
        citations: payload.get("attachmentIds").cloned().unwrap_or_else(|| json!([])),
    })
}

fn communication_class(purpose: &str) -> Result<&'static str, Failure> {
    match purpose {
        "SUBSCRIPTION_UPDATE" => Ok("SUBSCRIPTION_UPDATE"),
        "PRODUCT_MARKETING" | "DISCRETIONARY_OUTREACH" => Ok("DISCRETIONARY_EXTERNAL"),
        "INTERNAL_ACTION_REQUEST" => Ok("INTERNAL_ACTION_REQUEST"),
        "ENDPOINT_VERIFICATION" | "RIGHT_OF_REPLY_REQUEST" | "RIGHT_OF_REPLY_REMINDER"
        | "RESPONSE_RECEIPT" | "CORRECTION_STATUS" | "CORRECTION_RETRACTION_NOTICE"
        | "PRIVACY_TRANSACTIONAL_NOTICE" | "SECURITY_TRANSACTIONAL_NOTICE"
        | "INCIDENT_RECOVERY" | "SYSTEM_TRANSACTIONAL" => Ok("SYSTEM_TRANSACTIONAL"),
        _ => Err(Failure::Terminal("COMMUNICATION_PURPOSE_INVALID", purpose.to_owned())),
    }
}

fn endpoint_logical_type(channel: &str) -> &'static str {
    match channel {
        "SMTP_EMAIL" => "email-address",
        "SOLAPI_SMS" | "SOLAPI_KAKAO_BIZMESSAGE" | "TWILIO_VOICE"
        | "META_WHATSAPP_BUSINESS_CLOUD" => "phone-number",
        "SIGNED_WEBHOOK" => "uri",
        _ => "provider-identifier",
    }
}

fn required_text(value: &Value, key: &'static str) -> Result<String, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| Failure::Terminal("ACTION_PAYLOAD_FIELD_INVALID", key.to_owned()))
}

fn required_uuid(value: &Value, key: &'static str) -> Result<Uuid, Failure> {
    required_text(value, key)?
        .parse()
        .map_err(|_| Failure::Terminal("ACTION_PAYLOAD_FIELD_INVALID", key.to_owned()))
}

fn required_positive_i64(value: &Value, key: &'static str) -> Result<i64, Failure> {
    value
        .get(key)
        .and_then(Value::as_i64)
        .filter(|number| *number > 0)
        .ok_or_else(|| Failure::Terminal("ACTION_PAYLOAD_FIELD_INVALID", key.to_owned()))
}

fn required_digest(value: &Value, key: &'static str) -> Result<String, Failure> {
    required_text(value, key).and_then(|digest| {
        if is_sha256(&digest) {
            Ok(digest)
        } else {
            Err(Failure::Terminal("ACTION_PAYLOAD_FIELD_INVALID", key.to_owned()))
        }
    })
}
