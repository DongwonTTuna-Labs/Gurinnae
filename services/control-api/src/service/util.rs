use super::*;
use base64::engine::general_purpose::STANDARD as BASE64;

pub(super) fn command_parameters(
    request: &HttpRequest,
    payload: &Map<String, Value>,
) -> Map<String, Value> {
    let mut parameters = payload.clone();
    for (name, value) in request.match_info().iter() {
        parameters.insert(name.to_owned(), Value::String(value.to_owned()));
    }
    parameters
}

pub(super) fn query_parameters(
    operation: &str,
    request: &HttpRequest,
) -> Result<BTreeMap<String, String>, ServiceError> {
    let repeatable = repeatable_query_parameters(operation)?;
    let mut parameters = BTreeMap::<String, String>::new();
    for (key, value) in url::form_urlencoded::parse(request.query_string().as_bytes()) {
        let key = key.into_owned();
        let value = value.into_owned();
        if let Some(existing) = parameters.get_mut(&key) {
            if !repeatable.contains(&key) {
                return Err(ServiceError::InvalidRequest);
            }
            existing.push(',');
            existing.push_str(&value);
        } else {
            parameters.insert(key, value);
        }
    }
    for (name, value) in request.match_info().iter() {
        parameters.insert(name.to_owned(), value.to_owned());
    }
    Ok(parameters)
}

fn repeatable_query_parameters(operation: &str) -> Result<BTreeSet<String>, ServiceError> {
    let spec = SPEC
        .get_or_init(|| serde_json::from_str(CONTROL_OPENAPI).map_err(|_| ()))
        .as_ref()
        .map_err(|_| ServiceError::Persistence)?;
    let paths = spec
        .get("paths")
        .and_then(Value::as_object)
        .ok_or(ServiceError::Persistence)?;
    let definition = paths
        .values()
        .filter_map(Value::as_object)
        .flat_map(|path| path.values())
        .find(|candidate| candidate.get("operationId").and_then(Value::as_str) == Some(operation))
        .ok_or(ServiceError::Persistence)?;
    let parameters = definition
        .get("parameters")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    parameters
        .iter()
        .filter(|parameter| {
            parameter.get("in").and_then(Value::as_str) == Some("query")
                && parameter.pointer("/schema/type").and_then(Value::as_str) == Some("array")
        })
        .map(|parameter| {
            parameter
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or(ServiceError::Persistence)
        })
        .collect()
}

pub(super) fn uuid_value(payload: &Map<String, Value>, keys: &[&str]) -> Option<Uuid> {
    keys.iter().find_map(|key| {
        payload
            .get(*key)
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
    })
}

pub(super) fn uuid_array(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<Vec<Uuid>, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_array)
        .ok_or(ServiceError::InvalidRequest)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ServiceError::InvalidRequest)
        })
        .collect()
}

pub(super) fn string_value<'a>(payload: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    payload.get(key).and_then(Value::as_str)
}

pub(super) fn timestamp_value(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<Option<OffsetDateTime>, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(|value| {
            OffsetDateTime::parse(value, &Rfc3339).map_err(|_| ServiceError::InvalidRequest)
        })
        .transpose()
}

pub(super) fn decimal_string(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<rust_decimal::Decimal, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)?
        .parse()
        .map_err(|_| ServiceError::InvalidRequest)
}

pub(super) fn date_value(payload: &Map<String, Value>, key: &str) -> Result<Date, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)
        .and_then(|value| Date::parse(value, &format).map_err(|_| ServiceError::InvalidRequest))
}

pub(super) fn normalized_email(value: &str) -> Result<String, ServiceError> {
    let email = value.trim().to_ascii_lowercase();
    let Some((local, domain)) = email.split_once('@') else {
        return Err(ServiceError::InvalidRequest);
    };
    if local.is_empty()
        || domain.is_empty()
        || domain.starts_with('.')
        || domain.ends_with('.')
        || !domain.contains('.')
        || email.len() > 320
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(email)
}

pub(super) fn encrypt_control_field(
    keys: &EnvelopeKeyRing,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    plaintext: &[u8],
) -> Result<Vec<u8>, ServiceError> {
    let record_id = record_id.to_string();
    encrypt(
        "gurine-fe-v1",
        &keys.current,
        &[table, column, &record_id, logical_type, "1"],
        plaintext,
    )
    .map(String::into_bytes)
    .map_err(|_| ServiceError::Persistence)
}

pub(super) fn seal_action_request(
    operation: &str,
    mut payload: Value,
    field_keys: &EnvelopeKeyRing,
) -> Result<Value, ServiceError> {
    if !matches!(operation, "createActionProposal" | "updateActionDraft") {
        return Ok(payload);
    }
    let proposal_id = if operation == "createActionProposal" {
        Uuid::new_v4()
    } else {
        payload
            .get("proposalId")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .ok_or(ServiceError::InvalidRequest)?
    };
    let draft = serde_json::to_vec(payload.get("draft").ok_or(ServiceError::InvalidRequest)?)
        .map_err(|_| ServiceError::InvalidRequest)?;
    let rationale = serde_json::to_vec(
        payload
            .get("rationale")
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .map_err(|_| ServiceError::InvalidRequest)?;
    let sealed_draft = encrypt_control_field(
        field_keys,
        "ops.action_proposal_versions",
        "payload_encrypted",
        proposal_id,
        "json",
        &draft,
    )?;
    let sealed_rationale = encrypt_control_field(
        field_keys,
        "ops.action_proposal_versions",
        "rationale_encrypted",
        proposal_id,
        "json",
        &rationale,
    )?;
    let object = payload
        .as_object_mut()
        .ok_or(ServiceError::InvalidRequest)?;
    object.insert("_proposalId".to_owned(), json!(proposal_id));
    object.insert(
        "_payloadEncryptedBase64".to_owned(),
        json!(BASE64.encode(sealed_draft)),
    );
    object.insert(
        "_rationaleEncryptedBase64".to_owned(),
        json!(BASE64.encode(sealed_rationale)),
    );
    Ok(payload)
}

pub(super) fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

pub(super) fn valid_case_transition(current: &str, target: &str) -> bool {
    let (Some(current), Some(target)) = (investigation_state(current), investigation_state(target))
    else {
        return false;
    };
    CASE_TRANSITIONS
        .iter()
        .any(|transition| transition.from.contains(&current) && transition.to == target)
}

pub(super) fn investigation_state(value: &str) -> Option<InvestigationState> {
    InvestigationState::ALL
        .iter()
        .copied()
        .find(|state| state.as_str() == value)
}

pub(super) fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// RFC 8785-compatible JSON bytes for immutable cross-service digests.  The
/// agent snapshot contains only strings, UUIDs, arrays, objects and booleans;
/// rejecting non-integral numbers keeps this implementation lossless and
/// prevents a provider hash from depending on a language's float formatter.
pub(super) fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>, ServiceError> {
    fn write_value(value: &Value, out: &mut String) -> Result<(), ServiceError> {
        match value {
            Value::Null => out.push_str("null"),
            Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
            Value::Number(value) => {
                if !value.is_i64() && !value.is_u64() {
                    return Err(ServiceError::InvalidRequest);
                }
                out.push_str(&value.to_string());
            }
            Value::String(value) => {
                let encoded =
                    serde_json::to_string(value).map_err(|_| ServiceError::Persistence)?;
                out.push_str(&encoded);
            }
            Value::Array(values) => {
                out.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write_value(value, out)?;
                }
                out.push(']');
            }
            Value::Object(values) => {
                let mut keys = values.keys().collect::<Vec<_>>();
                keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
                out.push('{');
                for (index, key) in keys.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    let encoded =
                        serde_json::to_string(key).map_err(|_| ServiceError::Persistence)?;
                    out.push_str(&encoded);
                    out.push(':');
                    write_value(values.get(*key).ok_or(ServiceError::Persistence)?, out)?;
                }
                out.push('}');
            }
        }
        Ok(())
    }

    let mut out = String::new();
    write_value(value, &mut out)?;
    Ok(out.into_bytes())
}

pub(super) fn canonical_json_digest(value: &Value) -> Result<String, ServiceError> {
    Ok(sha256(&canonical_json_bytes(value)?))
}

pub(super) fn mapping_digest_matches(value: &Value, expected: &str) -> Result<bool, ServiceError> {
    let canonical = serde_json::to_vec(value).map_err(|_| ServiceError::InvalidRequest)?;
    Ok(sha256(&canonical) == expected)
}

pub(super) fn format_time(value: OffsetDateTime) -> Result<String, ServiceError> {
    value
        .format(&Rfc3339)
        .map_err(|_| ServiceError::Persistence)
}

pub(super) fn db(error: sqlx::Error) -> ServiceError {
    let database_error = error.as_database_error();
    let sql_state = database_error
        .and_then(|database| database.code())
        .map(|code| code.into_owned());
    let message = database_error.map(|database| database.message());
    let service_error = classify_database_error(sql_state.as_deref(), message);
    tracing::error!(
        sql_state = sql_state.as_deref().unwrap_or("NON_DATABASE"),
        classification = ?service_error,
        "control persistence operation failed"
    );
    service_error
}

fn classify_database_error(sql_state: Option<&str>, message: Option<&str>) -> ServiceError {
    match (sql_state, message) {
        (Some("42501"), Some("response_identity_step_up_invalid")) => ServiceError::StepUpRequired,
        (Some("0A000"), Some("LEGAL_HOLD_TARGET_UNSUPPORTED")) => {
            ServiceError::LegalHoldTargetUnsupported
        }
        (Some("0A000"), Some("PRIVACY_CORRECTION_TARGET_UNSUPPORTED")) => {
            ServiceError::PrivacyCorrectionTargetUnsupported
        }
        (Some("55000"), Some("r6d_entity_closure_legal_hold_active")) => {
            ServiceError::LegalHoldActive
        }
        (Some("55000"), Some("privacy_correction_legal_hold_active")) => {
            ServiceError::LegalHoldActive
        }
        (Some("22023"), _) => ServiceError::InvalidRequest,
        (Some("P0002"), _) => ServiceError::NotFound,
        (Some("40001"), _) => ServiceError::VersionConflict,
        (Some("23514" | "55000"), _) => ServiceError::PreconditionFailed,
        _ => ServiceError::Persistence,
    }
}

#[cfg(test)]
mod database_error_tests {
    use super::*;

    #[test]
    fn response_identity_step_up_error_has_one_narrow_typed_mapping() {
        assert!(matches!(
            classify_database_error(Some("42501"), Some("response_identity_step_up_invalid")),
            ServiceError::StepUpRequired
        ));
        assert!(matches!(
            classify_database_error(Some("42501"), Some("permission denied for table responses")),
            ServiceError::Persistence
        ));
        assert!(matches!(
            classify_database_error(Some("42501"), Some("privacy_step_up_authority_invalid")),
            ServiceError::Persistence
        ));
        assert!(matches!(
            classify_database_error(Some("23514"), Some("response_identity_step_up_invalid")),
            ServiceError::PreconditionFailed
        ));
    }

    #[test]
    fn entity_closure_active_hold_has_one_narrow_typed_mapping() {
        assert!(matches!(
            classify_database_error(Some("55000"), Some("r6d_entity_closure_legal_hold_active")),
            ServiceError::LegalHoldActive
        ));
        assert!(matches!(
            classify_database_error(Some("55000"), Some("another_precondition")),
            ServiceError::PreconditionFailed
        ));
        assert!(matches!(
            classify_database_error(Some("23514"), Some("r6d_entity_closure_legal_hold_active")),
            ServiceError::PreconditionFailed
        ));
        assert!(matches!(
            classify_database_error(Some("23514"), Some("BUSINESS_CALENDAR_STALE")),
            ServiceError::PreconditionFailed
        ));
    }

    #[test]
    fn privacy_correction_active_hold_has_one_narrow_typed_mapping() {
        assert!(matches!(
            classify_database_error(Some("55000"), Some("privacy_correction_legal_hold_active")),
            ServiceError::LegalHoldActive
        ));
        assert!(matches!(
            classify_database_error(Some("55000"), Some("PRIVACY_CORRECTION_LEGAL_HOLD_ACTIVE")),
            ServiceError::PreconditionFailed
        ));
        assert!(matches!(
            classify_database_error(
                Some("55000"),
                Some("privacy_correction_legal_hold_active: changed")
            ),
            ServiceError::PreconditionFailed
        ));
        assert!(matches!(
            classify_database_error(Some("23514"), Some("privacy_correction_legal_hold_active")),
            ServiceError::PreconditionFailed
        ));
    }

    #[test]
    fn r6d_unsupported_authority_errors_have_exact_typed_mappings() {
        assert!(matches!(
            classify_database_error(Some("0A000"), Some("LEGAL_HOLD_TARGET_UNSUPPORTED")),
            ServiceError::LegalHoldTargetUnsupported
        ));
        assert!(matches!(
            classify_database_error(Some("0A000"), Some("PRIVACY_CORRECTION_TARGET_UNSUPPORTED")),
            ServiceError::PrivacyCorrectionTargetUnsupported
        ));
        assert!(matches!(
            classify_database_error(Some("0A000"), Some("legal_hold_target_unsupported")),
            ServiceError::Persistence
        ));
        assert!(matches!(
            classify_database_error(Some("55000"), Some("LEGAL_HOLD_TARGET_UNSUPPORTED")),
            ServiceError::PreconditionFailed
        ));
        assert!(matches!(
            classify_database_error(
                Some("0A000"),
                Some("PRIVACY_CORRECTION_TARGET_UNSUPPORTED: response")
            ),
            ServiceError::Persistence
        ));
    }
}
