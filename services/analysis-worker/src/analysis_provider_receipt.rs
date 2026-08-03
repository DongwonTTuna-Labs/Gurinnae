const REQUIRED_FIELDS: &[&str] = &[
    "schemaVersion",
    "receiptId",
    "agentRunId",
    "providerTurnId",
    "providerMode",
    "providerConfigId",
    "providerCandidateId",
    "modelId",
    "modelConfigurationSha256",
    "semanticRequestSha256",
    "idempotencyKeySha256",
    "outcome",
    "proofKind",
    "proofSha256",
    "providerRequestIdHash",
    "usage",
    "pricing",
    "dataPolicy",
    "dispatchedAt",
    "observedAt",
    "completedAt",
    "receiptSha256",
];
const ALLOWED_FIELDS: &[&str] = &[
    "schemaVersion",
    "receiptId",
    "agentRunId",
    "providerTurnId",
    "providerMode",
    "providerConfigId",
    "providerCandidateId",
    "modelId",
    "modelConfigurationSha256",
    "semanticRequestSha256",
    "idempotencyKeySha256",
    "outcome",
    "proofKind",
    "proofSha256",
    "providerRequestIdHash",
    "usage",
    "pricing",
    "dataPolicy",
    "dispatchedAt",
    "observedAt",
    "completedAt",
    "receiptSha256",
];

#[expect(
    clippy::too_many_arguments,
    reason = "receipt validation binds every provider identity and request digest"
)]
fn validate_provider_receipt(
    receipt: &Value,
    run_id: Uuid,
    turn_id: Uuid,
    provider_config_id: Uuid,
    provider: &str,
    model: &str,
    request_sha256: &str,
    idempotency_hash: &str,
) -> Result<Uuid, Failure> {
    let object = receipt
        .as_object()
        .ok_or_else(|| invalid_receipt("object"))?;
    require_fields(object, REQUIRED_FIELDS)?;
    if object
        .keys()
        .any(|key| !ALLOWED_FIELDS.contains(&key.as_str()))
    {
        return Err(invalid_receipt("additional property"));
    }
    require_hashes(object)?;
    let receipt_id = parse_receipt_uuid(object, "receiptId")?;
    validate_binding(
        object,
        run_id,
        turn_id,
        provider_config_id,
        provider,
        model,
        request_sha256,
        idempotency_hash,
    )?;
    validate_nested(object)?;
    validate_receipt_digest(receipt, object)?;
    Ok(receipt_id)
}

fn invalid_receipt(detail: impl Into<String>) -> Failure {
    Failure::Terminal("PROVIDER_RECEIPT_INVALID", detail.into())
}

fn require_fields(object: &serde_json::Map<String, Value>, fields: &[&str]) -> Result<(), Failure> {
    for field in fields {
        if !object.contains_key(*field) {
            return Err(invalid_receipt(*field));
        }
    }
    Ok(())
}

fn valid_hash(value: Option<&Value>) -> bool {
    value.and_then(Value::as_str).is_some_and(|hash| {
        hash.len() == 64
            && hash
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    })
}

fn require_hashes(object: &serde_json::Map<String, Value>) -> Result<(), Failure> {
    for field in [
        "modelConfigurationSha256",
        "semanticRequestSha256",
        "idempotencyKeySha256",
        "proofSha256",
        "receiptSha256",
    ] {
        if !valid_hash(object.get(field)) {
            return Err(invalid_receipt(field));
        }
    }
    if let Some(value) = object.get("providerRequestIdHash")
        && !value.is_null()
        && !valid_hash(Some(value))
    {
        return Err(invalid_receipt("providerRequestIdHash"));
    }
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "receipt binding compares all immutable attempt identities"
)]
fn validate_binding(
    object: &serde_json::Map<String, Value>,
    run_id: Uuid,
    turn_id: Uuid,
    provider_config_id: Uuid,
    provider: &str,
    model: &str,
    request_sha256: &str,
    idempotency_hash: &str,
) -> Result<(), Failure> {
    if !valid_provider_candidate(provider)
        || model.is_empty()
        || model.chars().count() > 255
    {
        return Err(invalid_receipt("provider/model"));
    }
    if object.get("schemaVersion").and_then(Value::as_str) != Some("provider-receipt.v2")
        || parse_receipt_uuid(object, "agentRunId")? != run_id
        || parse_receipt_uuid(object, "providerTurnId")? != turn_id
        || parse_receipt_uuid(object, "providerConfigId")? != provider_config_id
        || object.get("providerMode").and_then(Value::as_str) != Some("EXTERNAL_APPROVED")
        || object.get("providerCandidateId").and_then(Value::as_str) != Some(provider)
        || object.get("modelId").and_then(Value::as_str) != Some(model)
        || object
            .get("modelConfigurationSha256")
            .and_then(Value::as_str)
            != Some(sha256(model.as_bytes()).as_str())
        || object.get("semanticRequestSha256").and_then(Value::as_str) != Some(request_sha256)
        || object.get("idempotencyKeySha256").and_then(Value::as_str) != Some(idempotency_hash)
    {
        return Err(invalid_receipt("binding"));
    }
    Ok(())
}

fn validate_nested(object: &serde_json::Map<String, Value>) -> Result<(), Failure> {
    let outcome = object
        .get("outcome")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !matches!(
        outcome,
        "ACCEPTED_FINAL"
            | "ACCEPTED_TOOL_CALL"
            | "DEFINITIVE_REJECTED"
            | "RATE_LIMITED"
            | "TIMED_OUT_BEFORE_SEND"
            | "OUTCOME_UNKNOWN"
            | "CANCELLED_CONFIRMED"
            | "NO_DISPATCH_CONFIRMED"
    ) {
        return Err(invalid_receipt("outcome"));
    }
    let usage = object
        .get("usage")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid_receipt("usage"))?;
    let pricing = object
        .get("pricing")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid_receipt("pricing"))?;
    let policy = object
        .get("dataPolicy")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid_receipt("dataPolicy"))?;
    require_nested_fields(usage, pricing, policy)?;
    validate_nested_shape(usage, pricing, policy)?;
    validate_nested_values(usage, pricing, policy)?;
    validate_nested_completion(object, pricing, outcome)?;
    validate_nested_proof(object)?;
    validate_nested_timestamps(object)?;
    Ok(())
}

fn validate_nested_shape(
    usage: &serde_json::Map<String, Value>,
    pricing: &serde_json::Map<String, Value>,
    policy: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    let allowed = [
        (usage, &["state", "inputUnits", "outputUnits", "cachedInputUnits", "billableUnits", "usageEvidenceSha256"] as &[&str]),
        (pricing, &["pricingVersion", "pricingSha256", "currency", "fxRateFactId", "reservedMicrosKrw", "actualMicrosKrw", "costState"]),
        (policy, &["classification", "processingRegion", "retentionMode", "trainingUse", "policyVersion", "policySha256", "rightsDecisionSetSha256"]),
    ];
    if allowed.iter().any(|(object, fields)| {
        object.keys().any(|key| !fields.contains(&key.as_str()))
    }) {
        return Err(invalid_receipt("nested additional property"));
    }
    Ok(())
}

fn validate_nested_values(
    usage: &serde_json::Map<String, Value>,
    pricing: &serde_json::Map<String, Value>,
    policy: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    for field in ["inputUnits", "outputUnits", "cachedInputUnits", "billableUnits"] {
        if usage.get(field).is_some_and(|value| {
            !value.is_null() && value.as_i64().is_none_or(|units| units < 0)
        }) {
            return Err(invalid_receipt(format!("usage.{field}")));
        }
    }
    for field in ["reservedMicrosKrw", "actualMicrosKrw"] {
        if pricing.get(field).is_some_and(|value| {
            !value.is_null() && value.as_i64().is_none_or(|amount| amount < 0)
        }) {
            return Err(invalid_receipt(format!("pricing.{field}")));
        }
    }
    if pricing.get("currency").and_then(Value::as_str) != Some("KRW")
        || !matches!(pricing.get("costState").and_then(Value::as_str), Some("RESERVED" | "ESTIMATED" | "SETTLED" | "RELEASED" | "RECONCILIATION_REQUIRED"))
        || !matches!(usage.get("state").and_then(Value::as_str), Some("NOT_APPLICABLE" | "ESTIMATED" | "PROVIDER_REPORTED" | "BILLING_VERIFIED" | "UNKNOWN"))
        || !matches!(policy.get("classification").and_then(Value::as_str), Some("PUBLIC" | "INTERNAL"))
        || !matches!(policy.get("retentionMode").and_then(Value::as_str), Some("ZERO_RETENTION" | "BOUNDED_PROVIDER_RETENTION" | "LOCAL_ONLY"))
        || policy
            .get("processingRegion")
            .and_then(Value::as_str)
            .is_none_or(|region| !valid_region(region))
    {
        return Err(invalid_receipt("nested enum/currency"));
    }
    if pricing
        .get("pricingVersion")
        .and_then(Value::as_str)
        .is_none_or(|version| version.is_empty() || version.chars().count() > 64)
        || policy
            .get("policyVersion")
            .and_then(Value::as_str)
            .is_none_or(|version| version.is_empty() || version.chars().count() > 64)
    {
        return Err(invalid_receipt("nested version"));
    }
    if let Some(value) = pricing.get("fxRateFactId")
        && !value.is_null()
        && value.as_str().and_then(|id| Uuid::parse_str(id).ok()).is_none()
    {
        return Err(invalid_receipt("pricing.fxRateFactId"));
    }
    if (!pricing
        .get("fxRateFactId")
        .is_some_and(|value| value.is_null() || value.as_str().is_some_and(|id| Uuid::parse_str(id).is_ok())))
        || !valid_hash(pricing.get("pricingSha256"))
        || pricing
            .get("currency")
            .and_then(Value::as_str)
            .is_none_or(|currency| currency.len() != 3 || !currency.bytes().all(|byte| byte.is_ascii_uppercase()))
        || !valid_optional_hash(usage.get("usageEvidenceSha256"))
        || !valid_hash(policy.get("policySha256"))
        || !valid_hash(policy.get("rightsDecisionSetSha256"))
        || policy.get("trainingUse").and_then(Value::as_str) != Some("PROHIBITED")
    {
        return Err(invalid_receipt("nested digest/policy"));
    }
    Ok(())
}

fn valid_region(region: &str) -> bool {
    let mut parts = region.split('-');
    let country_valid = parts.next().is_some_and(|country| {
        country.len() == 2 && country.bytes().all(|byte| byte.is_ascii_uppercase())
    });
    let suffix_valid = parts
        .next()
        .is_none_or(|suffix| {
            (1..=12).contains(&suffix.len())
                && suffix
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        })
        && parts.next().is_none();
    country_valid && suffix_valid
}

fn valid_provider_candidate(provider: &str) -> bool {
    let mut bytes = provider.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    provider.len() <= 128
        && (first.is_ascii_lowercase() || first.is_ascii_digit())
        && bytes.all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        })
}

fn valid_optional_hash(value: Option<&Value>) -> bool {
    value.is_none_or(|value| value.is_null() || valid_hash(Some(value)))
}

fn validate_nested_completion(
    object: &serde_json::Map<String, Value>,
    pricing: &serde_json::Map<String, Value>,
    outcome: &str,
) -> Result<(), Failure> {
    if matches!(outcome, "ACCEPTED_FINAL" | "ACCEPTED_TOOL_CALL")
        && (object.get("providerRequestIdHash").is_none_or(Value::is_null)
            || pricing.get("costState").and_then(Value::as_str) != Some("SETTLED")
            || pricing.get("actualMicrosKrw").and_then(Value::as_i64).is_none()
            || object.get("completedAt").is_none_or(Value::is_null))
    {
        return Err(invalid_receipt("settled completion"));
    }
    Ok(())
}

fn validate_nested_proof(object: &serde_json::Map<String, Value>) -> Result<(), Failure> {
    if !matches!(
        object.get("proofKind").and_then(Value::as_str),
        Some("AUTHENTICATED_RESPONSE_HEADERS" | "SIGNED_PROVIDER_RECEIPT" | "IDEMPOTENCY_LOOKUP" | "USAGE_LOOKUP" | "DEFINITIVE_NO_DISPATCH")
    ) {
        return Err(invalid_receipt("proofKind"));
    }
    Ok(())
}

fn validate_nested_timestamps(object: &serde_json::Map<String, Value>) -> Result<(), Failure> {
    for field in ["dispatchedAt", "observedAt"] {
        if !valid_timestamp(object.get(field)) {
            return Err(invalid_receipt(field));
        }
    }
    if let Some(value) = object.get("completedAt")
        && !value.is_null()
        && !valid_timestamp(Some(value))
    {
        return Err(invalid_receipt("completedAt"));
    }
    Ok(())
}

fn valid_timestamp(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .and_then(|timestamp| {
            time::OffsetDateTime::parse(timestamp, &time::format_description::well_known::Rfc3339)
                .ok()
        })
        .is_some()
}

fn require_nested_fields(
    usage: &serde_json::Map<String, Value>,
    pricing: &serde_json::Map<String, Value>,
    policy: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    require_nested(
        usage,
        &[
            "state",
            "inputUnits",
            "outputUnits",
            "cachedInputUnits",
            "billableUnits",
            "usageEvidenceSha256",
        ],
        "usage",
    )?;
    require_nested(
        pricing,
        &[
            "pricingVersion",
            "pricingSha256",
            "currency",
            "fxRateFactId",
            "reservedMicrosKrw",
            "actualMicrosKrw",
            "costState",
        ],
        "pricing",
    )?;
    require_nested(
        policy,
        &[
            "classification",
            "processingRegion",
            "retentionMode",
            "trainingUse",
            "policyVersion",
            "policySha256",
            "rightsDecisionSetSha256",
        ],
        "dataPolicy",
    )
}

fn require_nested(
    object: &serde_json::Map<String, Value>,
    fields: &[&str],
    prefix: &str,
) -> Result<(), Failure> {
    for field in fields {
        if !object.contains_key(*field) {
            return Err(invalid_receipt(format!("{prefix}.{field}")));
        }
    }
    Ok(())
}

fn validate_receipt_digest(
    receipt: &Value,
    object: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    let expected = object
        .get("receiptSha256")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_receipt("receiptSha256"))?;
    let mut unsigned = receipt.clone();
    unsigned
        .as_object_mut()
        .ok_or_else(|| invalid_receipt("object"))?
        .remove("receiptSha256");
    if sha256(&canonical_bytes(&unsigned)?) != expected {
        return Err(invalid_receipt("digest"));
    }
    Ok(())
}
