/// The pricing schedule is activated with the provider routing policy and is
/// copied into the budget reservation as `provider-pricing-v1`. Provider
/// reported prices are evidence only: the worker recomputes the settled
/// amount from this immutable local schedule and rejects a receipt whose
/// arithmetic or schedule digest differs.
struct LocalPricing {
    version: String,
    digest: String,
    input_micros_per_unit: i64,
    output_micros_per_unit: i64,
}

struct ProviderRequestData {
    request: Value,
}

impl LocalPricing {
    fn from_routing_policy(policy: &Value) -> Result<Self, Failure> {
        let value = policy
            .get("pricing")
            .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_UNAVAILABLE", "pricing".into()))?;
        let object = value
            .as_object()
            .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_INVALID", "object".into()))?;
        let version = required_text(object, "pricingVersion")?;
        let digest = required_hash(object, "pricingSha256")?;
        let input_micros_per_unit = required_nonnegative_i64(object, "inputMicrosKrwPerUnit")?;
        let output_micros_per_unit = required_nonnegative_i64(object, "outputMicrosKrwPerUnit")?;
        let canonical = json!({
            "currency": "KRW",
            "inputMicrosKrwPerUnit": input_micros_per_unit,
            "outputMicrosKrwPerUnit": output_micros_per_unit,
            "pricingVersion": version,
        });
        if sha256(&canonical_bytes(&canonical)?) != digest {
            return Err(Failure::Terminal(
                "PROVIDER_PRICING_INVALID",
                "pricingSha256".into(),
            ));
        }
        Ok(Self {
            version,
            digest,
            input_micros_per_unit,
            output_micros_per_unit,
        })
    }
}

fn required_text(object: &serde_json::Map<String, Value>, key: &str) -> Result<String, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty() && value.chars().count() <= 64)
        .map(str::to_owned)
        .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_INVALID", key.into()))
}

fn required_hash(object: &serde_json::Map<String, Value>, key: &str) -> Result<String, Failure> {
    let value = required_text(object, key)?;
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(Failure::Terminal("PROVIDER_PRICING_INVALID", key.into()));
    }
    Ok(value)
}

fn required_nonnegative_i64(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<i64, Failure> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or_else(|| Failure::Terminal("PROVIDER_PRICING_INVALID", key.into()))
}

fn provider_failure_code(outcome: &str) -> Result<&'static str, Failure> {
    match outcome {
        "DEFINITIVE_REJECTED" => Ok("PROVIDER_REJECTED"),
        "RATE_LIMITED" => Ok("PROVIDER_RATE_LIMITED"),
        "TIMED_OUT_BEFORE_SEND" => Ok("PROVIDER_TIMEOUT"),
        "OUTCOME_UNKNOWN" => Ok("PROVIDER_OUTCOME_UNKNOWN"),
        "CANCELLED_CONFIRMED" | "NO_DISPATCH_CONFIRMED" => Ok("PROVIDER_CANCELLED"),
        _ => Err(Failure::Retryable(
            "PROVIDER_OUTCOME_UNKNOWN",
            "unrecognized receipt outcome".into(),
        )),
    }
}

fn failure_detail(failure: &Failure) -> String {
    match failure {
        Failure::Terminal(code, detail) | Failure::Retryable(code, detail) => {
            format!("{code}:{detail}")
        }
    }
}

struct ProviderTurnIdentity {
    turn_id: Uuid,
    run_id: Uuid,
    idempotency_hash: String,
    request_redacted: Value,
    dataset_snapshot_id: Option<Uuid>,
    input_snapshot_sha256: String,
    prior_transcript_sha256: String,
    provider_config_id: Uuid,
    provider_mode: String,
    provider_candidate_id: String,
    model_id: String,
    model_configuration_sha256: String,
    routing_policy_version: String,
    routing_decision_sha256: String,
    prompt_id: String,
    prompt_version: String,
    prompt_sha256: String,
    output_schema_id: String,
    output_schema_version: String,
    output_schema_sha256: String,
    classification: String,
    model_use_rights_sha256: String,
    budget_reservation_key_sha256: String,
    dispatch_key_sha256: String,
    request_sha256: String,
    turn_sequence: i32,
    attempt_sequence: i32,
    dispatched_at: String,
}

fn redact_provider_payload(value: &mut Value) {
    if let Some(object) = value.as_object_mut() {
        // Evidence is a typed digest/locator graph, not raw source text. Keep
        // its exact hashes and source-use identities in the semantic request;
        // only free-form instructions pass through the generic redactor.
        if let Some(objective) = object.get_mut("objective") {
            gurine_observability::redaction::redact(objective);
        }
    }
}

fn parse_receipt_uuid(object: &serde_json::Map<String, Value>, key: &str) -> Result<Uuid, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("PROVIDER_RECEIPT_INVALID", key.into()))
}

fn receipt_cost_krw(receipt: &Value, pricing: &LocalPricing) -> Result<i64, Failure> {
    if !matches!(
        receipt.get("outcome").and_then(Value::as_str),
        Some("ACCEPTED_FINAL" | "ACCEPTED_TOOL_CALL")
    ) {
        return Err(Failure::Terminal(
            "PROVIDER_RESPONSE_INVALID",
            "final outcome required".into(),
        ));
    }
    if receipt
        .pointer("/pricing/costState")
        .and_then(Value::as_str)
        != Some("SETTLED")
    {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "settled pricing required".into(),
        ));
    }
    let pricing_object = receipt
        .get("pricing")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "pricing".into()))?;
    if pricing_object.get("pricingVersion").and_then(Value::as_str)
        != Some(pricing.version.as_str())
        || pricing_object.get("pricingSha256").and_then(Value::as_str)
            != Some(pricing.digest.as_str())
    {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "local pricing binding".into(),
        ));
    }
    let usage = receipt
        .get("usage")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "usage".into()))?;
    let input_units = usage
        .get("inputUnits")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "inputUnits".into()))?;
    let output_units = usage
        .get("outputUnits")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "outputUnits".into()))?;
    if input_units < 0 || output_units < 0 {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "negative usage".into(),
        ));
    }
    let calculated_micros = input_units
        .checked_mul(pricing.input_micros_per_unit)
        .and_then(|value| {
            output_units
                .checked_mul(pricing.output_micros_per_unit)
                .and_then(|output| value.checked_add(output))
        })
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "overflow".into()))?;
    let micros = pricing_object
        .get("actualMicrosKrw")
        .and_then(Value::as_i64)
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "actualMicrosKrw".into()))?;
    if micros < 0 || micros != calculated_micros {
        return Err(Failure::Terminal(
            "PROVIDER_COST_INVALID",
            "provider cost does not match local schedule".into(),
        ));
    }
    micros
        .checked_add(999_999)
        .and_then(|value| value.checked_div(1_000_000))
        .ok_or_else(|| Failure::Terminal("PROVIDER_COST_INVALID", "overflow".into()))
}
