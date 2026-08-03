fn parse_provider_control_claim(value: &Value) -> Result<ProviderControlClaim, Failure> {
    let object = value
        .as_object()
        .ok_or_else(|| provider_control_invalid("claim object"))?;
    let operation_id =
        ProviderControlOperationId::parse(required_claim_text(object, "operationId")?)?;
    validate_provider_control_claim_keys(object, operation_id)?;
    if required_claim_text(object, "schemaVersion")? != PROVIDER_CONTROL_CLAIM_SCHEMA {
        return Err(provider_control_invalid("schemaVersion"));
    }
    let execution_id = required_claim_uuid(object, "executionId")?;
    let generation = required_claim_positive_i64(object, "generation")?;
    let attempt_id = required_claim_uuid(object, "attemptId")?;
    let fencing_token = required_claim_positive_i64(object, "fencingToken")?;
    for key in [
        "executionDigest",
        "approvalDigest",
        "actionDetailDigest",
        "targetRequestSha256",
        "providerConfigurationDigest",
        "providerIdempotencyKeySha256",
    ] {
        required_claim_sha256(object, key)?;
    }
    if operation_id != ProviderControlOperationId::TestProviderConnection
        || object.contains_key("reasonDigest")
    {
        required_claim_sha256(object, "reasonDigest")?;
    }
    required_claim_text(object, "providerReference")?;
    required_claim_uuid(object, "creatorActorId")?;
    let expires_at = required_claim_text(object, "expiresAt")?;
    time::OffsetDateTime::parse(
        expires_at,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| provider_control_invalid("expiresAt"))?;
    let provider_id = required_claim_uuid(object, "providerId")?;
    let expected_provider_version =
        required_claim_positive_i64(object, "expectedProviderVersion")?;
    let provider_routing_snapshot = object
        .get("providerRoutingSnapshot")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| provider_control_invalid("providerRoutingSnapshot"))?;
    let provider_idempotency_key_sha256 =
        required_claim_sha256(object, "providerIdempotencyKeySha256")?.to_owned();
    let branch = parse_provider_control_branch(object, operation_id)?;
    Ok(ProviderControlClaim {
        execution_id,
        generation,
        attempt_id,
        fencing_token,
        operation_id,
        provider_id,
        expected_provider_version,
        provider_routing_snapshot,
        provider_idempotency_key_sha256,
        branch,
    })
}

fn parse_provider_control_branch(
    object: &serde_json::Map<String, Value>,
    operation_id: ProviderControlOperationId,
) -> Result<ProviderControlBranch, Failure> {
    match operation_id {
        ProviderControlOperationId::DisableProviderRouting => Ok(ProviderControlBranch::Disable),
        ProviderControlOperationId::TestProviderConnection => Ok(ProviderControlBranch::Test {
            model: required_claim_text(object, "testModel")?.to_owned(),
        }),
        ProviderControlOperationId::UpgradeProviderModel => {
            let policy = object
                .get("requestedDataPolicy")
                .ok_or_else(|| provider_control_invalid("requestedDataPolicy"))?;
            if !policy.is_null() {
                validate_provider_control_requested_policy(policy)?;
            }
            Ok(ProviderControlBranch::Upgrade {
                model: required_claim_text(object, "targetModelId")?.to_owned(),
            })
        }
        ProviderControlOperationId::SetModelAutoUpgrade => {
            let enabled = object
                .get("autoUpgradeEnabled")
                .and_then(Value::as_bool)
                .ok_or_else(|| provider_control_invalid("autoUpgradeEnabled"))?;
            let track = object
                .get("autoUpgradeTrack")
                .ok_or_else(|| provider_control_invalid("autoUpgradeTrack"))?
                .as_str()
                .map(str::trim)
                .filter(|value| !value.is_empty() && value.len() <= 255)
                .map(str::to_owned);
            if !object["autoUpgradeTrack"].is_null() && track.is_none() {
                return Err(provider_control_invalid("autoUpgradeTrack"));
            }
            Ok(ProviderControlBranch::AutoUpgrade { enabled, track })
        }
    }
}

fn validate_provider_control_requested_policy(value: &Value) -> Result<(), Failure> {
    let object = value
        .as_object()
        .ok_or_else(|| provider_control_invalid("requestedDataPolicy"))?;
    const KEYS: &[&str] = &[
        "processingRegion",
        "retentionMode",
        "policyVersion",
        "policySha256",
    ];
    if object.len() != KEYS.len() || KEYS.iter().any(|key| !object.contains_key(*key)) {
        return Err(provider_control_invalid("requestedDataPolicy keys"));
    }
    let processing_region = required_policy_text(object, "processingRegion")?;
    let retention_mode = required_policy_text(object, "retentionMode")?;
    let policy_version = required_policy_text(object, "policyVersion")?;
    let policy_sha256 = required_claim_sha256(object, "policySha256")?;
    if !valid_region(processing_region)
        || !matches!(
            retention_mode,
            "ZERO_RETENTION" | "BOUNDED_PROVIDER_RETENTION" | "LOCAL_ONLY"
        )
        || policy_version.len() > 64
    {
        return Err(provider_control_invalid("requestedDataPolicy value"));
    }
    let canonical = json!({
        "policyVersion": policy_version,
        "processingRegion": processing_region,
        "retentionMode": retention_mode,
    });
    if sha256(&canonical_bytes(&canonical)?) != policy_sha256 {
        return Err(provider_control_invalid(
            "requestedDataPolicy policySha256",
        ));
    }
    Ok(())
}

fn validate_provider_control_claim_keys(
    object: &serde_json::Map<String, Value>,
    operation_id: ProviderControlOperationId,
) -> Result<(), Failure> {
    const COMMON: &[&str] = &[
        "schemaVersion",
        "executionId",
        "generation",
        "attemptId",
        "fencingToken",
        "executionDigest",
        "approvalDigest",
        "actionDetailDigest",
        "targetRequestSha256",
        "operationId",
        "providerId",
        "providerReference",
        "expectedProviderVersion",
        "creatorActorId",
        "providerRoutingSnapshot",
        "providerConfigurationDigest",
        "providerIdempotencyKeySha256",
        "expiresAt",
    ];
    let (required_branch, optional): (&[&str], &[&str]) = match operation_id {
        ProviderControlOperationId::DisableProviderRouting => (&["reasonDigest"], &[]),
        ProviderControlOperationId::TestProviderConnection => (&["testModel"], &["reasonDigest"]),
        ProviderControlOperationId::UpgradeProviderModel => {
            (&["reasonDigest", "targetModelId", "requestedDataPolicy"], &[])
        }
        ProviderControlOperationId::SetModelAutoUpgrade => {
            (&["reasonDigest", "autoUpgradeEnabled", "autoUpgradeTrack"], &[])
        }
    };
    if COMMON
        .iter()
        .chain(required_branch.iter())
        .any(|key| !object.contains_key(*key))
        || object.keys().any(|key| {
            !COMMON.contains(&key.as_str())
                && !required_branch.contains(&key.as_str())
                && !optional.contains(&key.as_str())
        })
    {
        return Err(provider_control_invalid("claim keys"));
    }
    Ok(())
}

fn required_positive_i64_at(value: &Value, pointer: &str) -> Result<i64, Failure> {
    value
        .pointer(pointer)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| provider_control_invalid(pointer))
}

fn required_sha256_at(value: &Value, pointer: &str) -> Result<String, Failure> {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .filter(|value| is_lower_sha256(value))
        .map(str::to_owned)
        .ok_or_else(|| provider_control_invalid(pointer))
}

fn required_claim_text<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &str,
) -> Result<&'a str, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && *value == value.trim() && value.len() <= 16_384)
        .ok_or_else(|| provider_control_invalid(key))
}

fn required_policy_text<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &str,
) -> Result<&'a str, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && *value == value.trim())
        .ok_or_else(|| provider_control_invalid(key))
}

fn required_claim_uuid(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Uuid, Failure> {
    required_claim_text(object, key)?
        .parse()
        .map_err(|_| provider_control_invalid(key))
}

fn required_claim_positive_i64(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<i64, Failure> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| provider_control_invalid(key))
}

fn required_claim_sha256<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &str,
) -> Result<&'a str, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_lower_sha256(value))
        .ok_or_else(|| provider_control_invalid(key))
}

fn provider_control_invalid(detail: impl Into<String>) -> Failure {
    Failure::Terminal("PROVIDER_CONTROL_EXECUTION_INVALID", detail.into())
}
