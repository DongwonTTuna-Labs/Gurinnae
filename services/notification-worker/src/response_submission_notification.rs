const RESPONSE_SUBMITTED_V2_FIELDS: [&str; 8] = [
    "responseSubmissionId",
    "responseRequestId",
    "responseRequestVersion",
    "responseRequestBindingDigest",
    "submissionSha256",
    "receiptVersion",
    "receiptDigest",
    "submittedAt",
];

const RESPONSE_SUBMISSION_NOTIFICATION_AUTHORITY_FIELDS: [&str; 10] = [
    "eventId",
    "eventEnvelopeDigest",
    "responseSubmissionId",
    "responseRequestId",
    "responseRequestVersion",
    "responseRequestBindingDigest",
    "submissionSha256",
    "receiptVersion",
    "receiptDigest",
    "submittedAt",
];

#[derive(Clone, Debug, Eq, PartialEq)]
struct ResponseSubmissionNotificationV2 {
    response_submission_id: Uuid,
    response_request_id: Uuid,
    response_request_version: i64,
    response_request_binding_digest: String,
    submission_sha256: String,
    receipt_version: i64,
    receipt_digest: String,
    submitted_at: time::OffsetDateTime,
}

async fn prepare_response_submitted_v2(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    let submitted = parse_response_submission_notification_v2(
        &event.payload,
        event.aggregate_id,
        event.aggregate_version,
    )?;
    let authority = sqlx::query_scalar::<_, serde_json::Value>(
        "SELECT intake.verify_response_submission_notification_v2($1,$2)",
    )
    .bind(event.id)
    .bind(&event.payload)
    .fetch_one(&state.pool)
    .await
    .map_err(classify_response_submission_verifier_error)?;
    let verified =
        validate_response_submission_notification_authority(&authority, event, &submitted)?;
    let (subject, text, html) = response_submission_internal_task_message(&verified);
    Ok((state.reply_to.clone(), subject, text, html))
}

fn parse_response_submission_notification_v2(
    payload: &serde_json::Value,
    aggregate_id: Uuid,
    aggregate_version: i64,
) -> Result<ResponseSubmissionNotificationV2, WorkerError> {
    let object = closed_response_submission_object(payload, &RESPONSE_SUBMITTED_V2_FIELDS)?;
    let response_submission_id = response_submission_uuid(object, "responseSubmissionId")?;
    let response_request_id = response_submission_uuid(object, "responseRequestId")?;
    let response_request_version =
        response_submission_positive_version(object, "responseRequestVersion")?;
    let receipt_version = response_submission_positive_version(object, "receiptVersion")?;
    if response_submission_id != aggregate_id || receipt_version != aggregate_version {
        return Err(WorkerError::Contract);
    }
    Ok(ResponseSubmissionNotificationV2 {
        response_submission_id,
        response_request_id,
        response_request_version,
        response_request_binding_digest: response_submission_digest(
            object,
            "responseRequestBindingDigest",
        )?,
        submission_sha256: response_submission_digest(object, "submissionSha256")?,
        receipt_version,
        receipt_digest: response_submission_digest(object, "receiptDigest")?,
        submitted_at: response_submission_timestamp(object, "submittedAt")?,
    })
}

fn validate_response_submission_notification_authority(
    authority: &serde_json::Value,
    event: &ClaimedEvent,
    expected: &ResponseSubmissionNotificationV2,
) -> Result<ResponseSubmissionNotificationV2, WorkerError> {
    let object = closed_response_submission_object(
        authority,
        &RESPONSE_SUBMISSION_NOTIFICATION_AUTHORITY_FIELDS,
    )?;
    let event_id = response_submission_uuid(object, "eventId")?;
    if event_id != event.id {
        return Err(WorkerError::Contract);
    }
    response_submission_digest(object, "eventEnvelopeDigest")?;

    let mut verified_payload = serde_json::Map::with_capacity(RESPONSE_SUBMITTED_V2_FIELDS.len());
    for field in RESPONSE_SUBMITTED_V2_FIELDS {
        let verified_value = object.get(field).ok_or(WorkerError::Contract)?;
        let event_value = event.payload.get(field).ok_or(WorkerError::Contract)?;
        if verified_value != event_value {
            return Err(WorkerError::Contract);
        }
        verified_payload.insert(field.to_owned(), verified_value.clone());
    }
    let verified = parse_response_submission_notification_v2(
        &serde_json::Value::Object(verified_payload),
        event.aggregate_id,
        event.aggregate_version,
    )?;
    if &verified != expected {
        return Err(WorkerError::Contract);
    }
    Ok(verified)
}

fn closed_response_submission_object<'a>(
    payload: &'a serde_json::Value,
    allowed_fields: &[&str],
) -> Result<&'a serde_json::Map<String, serde_json::Value>, WorkerError> {
    let object = payload.as_object().ok_or(WorkerError::Contract)?;
    if object.len() != allowed_fields.len()
        || object
            .keys()
            .any(|field| !allowed_fields.contains(&field.as_str()))
        || allowed_fields
            .iter()
            .any(|field| !object.contains_key(*field))
    {
        return Err(WorkerError::Contract);
    }
    Ok(object)
}

fn response_submission_uuid(
    payload: &serde_json::Map<String, serde_json::Value>,
    field: &str,
) -> Result<Uuid, WorkerError> {
    payload
        .get(field)
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(WorkerError::Contract)
}

fn response_submission_positive_version(
    payload: &serde_json::Map<String, serde_json::Value>,
    field: &str,
) -> Result<i64, WorkerError> {
    payload
        .get(field)
        .and_then(serde_json::Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or(WorkerError::Contract)
}

fn response_submission_digest(
    payload: &serde_json::Map<String, serde_json::Value>,
    field: &str,
) -> Result<String, WorkerError> {
    payload
        .get(field)
        .and_then(serde_json::Value::as_str)
        .filter(|value| {
            value.len() == 64
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
        })
        .map(str::to_owned)
        .ok_or(WorkerError::Contract)
}

fn response_submission_timestamp(
    payload: &serde_json::Map<String, serde_json::Value>,
    field: &str,
) -> Result<time::OffsetDateTime, WorkerError> {
    let value = payload
        .get(field)
        .and_then(serde_json::Value::as_str)
        .ok_or(WorkerError::Contract)?;
    time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
        .map_err(|_| WorkerError::Contract)
}

fn classify_response_submission_verifier_error(error: sqlx::Error) -> WorkerError {
    let is_contract_error = error
        .as_database_error()
        .and_then(|database_error| database_error.code())
        .is_some_and(|code| matches!(code.as_ref(), "22023" | "23514" | "55000"));
    if is_contract_error {
        WorkerError::Contract
    } else {
        WorkerError::Database
    }
}

fn response_submission_internal_task_message(
    submitted: &ResponseSubmissionNotificationV2,
) -> (String, String, String) {
    let subject = "구린네 소명 제출 검토".to_owned();
    let text = format!(
        "소명 제출 검토 필요\n제출 ID: {}\n소명 요청 ID: {}",
        submitted.response_submission_id, submitted.response_request_id
    );
    let html = format!(
        "<p>소명 제출 검토 필요</p><p>제출 ID: {}</p><p>소명 요청 ID: {}</p>",
        submitted.response_submission_id, submitted.response_request_id
    );
    (subject, text, html)
}

#[cfg(test)]
mod response_submission_notification_tests {
    use super::*;

    fn event(payload: serde_json::Value) -> ClaimedEvent {
        ClaimedEvent {
            consumer_id: "notification-worker".to_owned(),
            id: Uuid::parse_str("41000000-0000-4000-8000-000000000001").expect("fixture UUID"),
            event_type: "notification.response_submitted.v2".to_owned(),
            aggregate_id: Uuid::parse_str("41000000-0000-4000-8000-000000000002")
                .expect("fixture UUID"),
            aggregate_version: 3,
            payload,
        }
    }

    fn payload() -> serde_json::Value {
        serde_json::json!({
            "responseSubmissionId": "41000000-0000-4000-8000-000000000002",
            "responseRequestId": "41000000-0000-4000-8000-000000000003",
            "responseRequestVersion": 7,
            "responseRequestBindingDigest": "a".repeat(64),
            "submissionSha256": "b".repeat(64),
            "receiptVersion": 3,
            "receiptDigest": "c".repeat(64),
            "submittedAt": "2026-08-01T12:34:56Z"
        })
    }

    fn authority(event: &ClaimedEvent) -> serde_json::Value {
        let mut value = event.payload.clone();
        let object = value.as_object_mut().expect("fixture object");
        object.insert("eventId".to_owned(), serde_json::json!(event.id));
        object.insert(
            "eventEnvelopeDigest".to_owned(),
            serde_json::json!("d".repeat(64)),
        );
        value
    }

    #[test]
    fn response_submission_v2_requires_closed_exact_event_binding() {
        let valid = event(payload());
        let parsed = parse_response_submission_notification_v2(
            &valid.payload,
            valid.aggregate_id,
            valid.aggregate_version,
        )
        .expect("valid response submission notification");
        assert_eq!(parsed.response_submission_id, valid.aggregate_id);
        assert_eq!(parsed.receipt_version, valid.aggregate_version);
        assert!(
            parse_response_submission_notification_v2(
                &valid.payload,
                Uuid::new_v4(),
                valid.aggregate_version
            )
            .is_err()
        );
        assert!(
            parse_response_submission_notification_v2(
                &valid.payload,
                valid.aggregate_id,
                valid.aggregate_version + 1
            )
            .is_err()
        );

        let mut unknown = valid.payload.clone();
        unknown
            .as_object_mut()
            .expect("fixture object")
            .insert("requestToken".to_owned(), serde_json::json!("forbidden"));
        assert!(
            parse_response_submission_notification_v2(
                &unknown,
                valid.aggregate_id,
                valid.aggregate_version
            )
            .is_err()
        );

        let mut nil_id = valid.payload.clone();
        nil_id["responseRequestId"] = serde_json::json!(Uuid::nil());
        assert!(
            parse_response_submission_notification_v2(
                &nil_id,
                valid.aggregate_id,
                valid.aggregate_version
            )
            .is_err()
        );

        let mut upper_digest = valid.payload.clone();
        upper_digest["submissionSha256"] = serde_json::json!("A".repeat(64));
        assert!(
            parse_response_submission_notification_v2(
                &upper_digest,
                valid.aggregate_id,
                valid.aggregate_version
            )
            .is_err()
        );

        let mut zero_version = valid.payload.clone();
        zero_version["responseRequestVersion"] = serde_json::json!(0);
        assert!(
            parse_response_submission_notification_v2(
                &zero_version,
                valid.aggregate_id,
                valid.aggregate_version
            )
            .is_err()
        );

        let mut invalid_time = valid.payload.clone();
        invalid_time["submittedAt"] = serde_json::json!("2026-08-01");
        assert!(
            parse_response_submission_notification_v2(
                &invalid_time,
                valid.aggregate_id,
                valid.aggregate_version
            )
            .is_err()
        );
    }

    #[test]
    fn verifier_authority_must_match_event_and_all_eight_payload_values() {
        let event = event(payload());
        let parsed = parse_response_submission_notification_v2(
            &event.payload,
            event.aggregate_id,
            event.aggregate_version,
        )
        .expect("valid event");
        let verified = validate_response_submission_notification_authority(
            &authority(&event),
            &event,
            &parsed,
        )
        .expect("matching authority");
        assert_eq!(verified, parsed);

        let mut changed = authority(&event);
        changed["receiptDigest"] = serde_json::json!("e".repeat(64));
        assert!(
            validate_response_submission_notification_authority(&changed, &event, &parsed).is_err()
        );

        let mut extra = authority(&event);
        extra["partyName"] = serde_json::json!("노출 금지");
        assert!(
            validate_response_submission_notification_authority(&extra, &event, &parsed).is_err()
        );
    }

    #[test]
    fn internal_task_template_contains_only_safe_submission_and_request_ids() {
        let event = event(payload());
        let parsed = parse_response_submission_notification_v2(
            &event.payload,
            event.aggregate_id,
            event.aggregate_version,
        )
        .expect("valid event");
        let (subject, text, html) = response_submission_internal_task_message(&parsed);
        let rendered = format!("{subject}\n{text}\n{html}");
        assert!(rendered.contains(&parsed.response_submission_id.to_string()));
        assert!(rendered.contains(&parsed.response_request_id.to_string()));
        assert!(!rendered.contains(&parsed.submission_sha256));
        assert!(!rendered.contains(&parsed.receipt_digest));
        assert!(!rendered.contains("respond/receipt"));
        assert!(!rendered.contains("token"));
    }
}
