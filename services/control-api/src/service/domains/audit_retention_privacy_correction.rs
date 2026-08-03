use super::*;

const PUBLIC_FIELDS: &[&str] = &[
    "retentionRequestId",
    "expectedDecisionVersion",
    "targetObjectType",
    "targetObjectId",
    "fieldPath",
    "currentValueDigest",
    "requestedValue",
    "evidenceIds",
    "reason",
];

const TARGET_OBJECT_TYPES: &[&str] = &[
    "RESPONSE",
    "CORRECTION",
    "SUBSCRIPTION",
    "COMMUNICATION_ENDPOINT",
    "PUBLICATION",
    "EVIDENCE",
    "AUDIT_SUBJECT_RECORD",
];

const CORRECTION_TARGET_ALLOWLIST: &[(&str, &str)] = &[("RESPONSE", "/partyName")];

pub(super) fn validate(payload: &Map<String, Value>) -> Result<(), ServiceError> {
    if payload.len() != PUBLIC_FIELDS.len()
        || PUBLIC_FIELDS
            .iter()
            .any(|field| !payload.contains_key(*field))
    {
        return Err(ServiceError::InvalidRequest);
    }
    required_uuid(payload, "retentionRequestId")?;
    required_uuid(payload, "targetObjectId")?;
    payload
        .get("expectedDecisionVersion")
        .and_then(Value::as_i64)
        .filter(|version| *version >= 0)
        .ok_or(ServiceError::InvalidRequest)?;
    let target_object_type = string_value(payload, "targetObjectType")
        .filter(|kind| TARGET_OBJECT_TYPES.contains(kind))
        .ok_or(ServiceError::InvalidRequest)?;
    let field_path = string_value(payload, "fieldPath")
        .filter(|path| valid_field_path(path))
        .ok_or(ServiceError::InvalidRequest)?;
    string_value(payload, "currentValueDigest")
        .filter(|digest| is_sha256(digest))
        .ok_or(ServiceError::InvalidRequest)?;
    string_value(payload, "requestedValue")
        .filter(|value| {
            let count = value.chars().count();
            (1..=10_000).contains(&count) && !value.contains('\0')
        })
        .ok_or(ServiceError::InvalidRequest)?;
    bounded_text(payload, "reason", 4_000)?;
    validate_evidence_ids(payload)?;
    if !CORRECTION_TARGET_ALLOWLIST.contains(&(target_object_type, field_path)) {
        return Err(ServiceError::PrivacyCorrectionTargetUnsupported);
    }
    Ok(())
}

fn required_uuid(payload: &Map<String, Value>, field: &str) -> Result<Uuid, ServiceError> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)
}

fn validate_evidence_ids(payload: &Map<String, Value>) -> Result<(), ServiceError> {
    let values = payload
        .get("evidenceIds")
        .and_then(Value::as_array)
        .filter(|values| (1..=100).contains(&values.len()))
        .ok_or(ServiceError::InvalidRequest)?;
    let ids = values
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
                .ok_or(ServiceError::InvalidRequest)
        })
        .collect::<Result<BTreeSet<_>, _>>()?;
    if ids.len() != values.len() {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn valid_field_path(path: &str) -> bool {
    let count = path.chars().count();
    if !(1..=1_000).contains(&count) || !path.starts_with('/') || path.chars().any(char::is_control)
    {
        return false;
    }
    let mut chars = path.chars();
    while let Some(character) = chars.next() {
        if character == '~' && !matches!(chars.next(), Some('0' | '1')) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_payload(kind: &str) -> Map<String, Value> {
        json!({
            "retentionRequestId":"10000000-0000-4000-8000-000000000001",
            "expectedDecisionVersion":2,
            "targetObjectType":kind,
            "targetObjectId":"10000000-0000-4000-8000-000000000002",
            "fieldPath":"/partyName",
            "currentValueDigest":"a".repeat(64),
            "requestedValue":"정정된 표시 이름",
            "evidenceIds":["10000000-0000-4000-8000-000000000003"],
            "reason":"증거와 일치하도록 정정 계획을 기록함"
        })
        .as_object()
        .cloned()
        .unwrap_or_default()
    }

    #[test]
    fn only_response_party_name_is_authorized() {
        assert_eq!(CORRECTION_TARGET_ALLOWLIST, &[("RESPONSE", "/partyName")]);
        assert!(validate(&valid_payload("RESPONSE")).is_ok());

        for kind in TARGET_OBJECT_TYPES
            .iter()
            .copied()
            .filter(|kind| *kind != "RESPONSE")
        {
            assert!(
                matches!(
                    validate(&valid_payload(kind)),
                    Err(ServiceError::PrivacyCorrectionTargetUnsupported)
                ),
                "kind={kind}"
            );
        }

        let mut unsupported_response_field = valid_payload("RESPONSE");
        unsupported_response_field.insert("fieldPath".to_owned(), json!("/displayName"));
        assert!(matches!(
            validate(&unsupported_response_field),
            Err(ServiceError::PrivacyCorrectionTargetUnsupported)
        ));
    }

    #[test]
    fn field_path_is_only_an_absolute_rfc6901_syntax_guard() {
        let mut payload = valid_payload("RESPONSE");
        for valid in ["/", "/a//b", "/future~0field", "/escaped~1slash"] {
            payload.insert("fieldPath".to_owned(), json!(valid));
            assert!(
                matches!(
                    validate(&payload),
                    Err(ServiceError::PrivacyCorrectionTargetUnsupported)
                ),
                "path={valid:?}"
            );
        }

        for invalid in ["", "relative", "/bad~", "/bad~2escape", "/bad\0path"] {
            payload.insert("fieldPath".to_owned(), json!(invalid));
            assert!(validate(&payload).is_err(), "path={invalid:?}");
        }
    }

    #[test]
    fn evidence_set_and_server_only_fields_are_closed() {
        let mut payload = valid_payload("EVIDENCE");
        let duplicate = "10000000-0000-4000-8000-000000000003";
        payload.insert("evidenceIds".to_owned(), json!([duplicate, duplicate]));
        assert!(validate(&payload).is_err());

        let mut payload = valid_payload("EVIDENCE");
        payload.insert(
            "requestedValueCiphertextBase64".to_owned(),
            json!("caller-supplied"),
        );
        assert!(validate(&payload).is_err());
    }
}
