use time::OffsetDateTime;

const RELAY_PROVIDER: &str = "relay";
const RELAY_CHAT_PATH: &str = "/v1/chat/completions";
const RELAY_MODELS_PATH: &str = "/v1/models";

#[path = "analysis_relay_request.rs"]
mod analysis_relay_request;
#[path = "analysis_relay_response.rs"]
mod analysis_relay_response;

use analysis_relay_request::relay_chat_request;
use analysis_relay_response::{
    RelayEnvelope, RelayUsage, bounded_relay_text, is_lower_sha256,
    observe_relay_gateway_response, parse_relay_completion, relay_actual_cost_micros,
    relay_internal_response, relay_response_error,
};

#[derive(Clone, Debug)]
struct RelayDataPolicy {
    processing_region: String,
    retention_mode: String,
    policy_version: String,
    policy_sha256: String,
}

impl RelayDataPolicy {
    fn from_routing_policy(routing: &Value) -> Result<Self, Failure> {
        let policy = routing
            .get("dataPolicy")
            .and_then(Value::as_object)
            .ok_or_else(|| relay_policy_error("dataPolicy"))?;
        if policy.get("state").and_then(Value::as_str) != Some("CONFIGURED") {
            return Err(Failure::Terminal(
                "PROVIDER_DATA_POLICY_UNCONFIGURED",
                "relay".to_owned(),
            ));
        }
        let processing_region = relay_policy_text(policy, "processingRegion")?;
        let retention_mode = relay_policy_text(policy, "retentionMode")?;
        let policy_version = relay_policy_text(policy, "policyVersion")?;
        let policy_sha256 = relay_policy_text(policy, "policySha256")?;
        if !valid_region(&processing_region)
            || !matches!(
                retention_mode.as_str(),
                "ZERO_RETENTION" | "BOUNDED_PROVIDER_RETENTION" | "LOCAL_ONLY"
            )
            || !is_lower_sha256(&policy_sha256)
        {
            return Err(relay_policy_error("value"));
        }
        let canonical = json!({
            "policyVersion": policy_version,
            "processingRegion": processing_region,
            "retentionMode": retention_mode,
        });
        if sha256(&canonical_bytes(&canonical)?) != policy_sha256 {
            return Err(relay_policy_error("policySha256"));
        }
        Ok(Self {
            processing_region,
            retention_mode,
            policy_version,
            policy_sha256,
        })
    }

    fn receipt_value(&self, classification: &str, rights_sha256: &str) -> Value {
        json!({
            "classification": classification,
            "processingRegion": self.processing_region,
            "retentionMode": self.retention_mode,
            "trainingUse": "PROHIBITED",
            "policyVersion": self.policy_version,
            "policySha256": self.policy_sha256,
            "rightsDecisionSetSha256": rights_sha256,
        })
    }
}

fn relay_policy_text(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<String, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty() && value.chars().count() <= 64)
        .map(str::to_owned)
        .ok_or_else(|| relay_policy_error(key))
}

fn relay_policy_error(detail: impl Into<String>) -> Failure {
    Failure::Terminal("PROVIDER_DATA_POLICY_INVALID", detail.into())
}

#[derive(Debug)]
struct RelayWireRequest {
    body: Value,
    request_sha256: String,
}

struct ProviderDispatchResponse {
    response: reqwest::Response,
    request_sha256: String,
}

fn relay_target_has_path(target: &str, expected_path: &str) -> bool {
    target.parse::<reqwest::Url>().is_ok_and(|url| {
        url.scheme() == "https"
            && url.path() == expected_path
            && url.query().is_none()
            && url.fragment().is_none()
    })
}

fn validate_relay_target(target: &str, expected_path: &str) -> Result<(), Failure> {
    if relay_target_has_path(target, expected_path) {
        return Ok(());
    }
    Err(Failure::Terminal(
        "PROVIDER_TARGET_INVALID",
        target.to_owned(),
    ))
}

#[cfg(test)]
mod relay_protocol_tests {
    use super::*;

    fn policy() -> Value {
        let settings = json!({
            "policyVersion": "relay-policy-v1",
            "processingRegion": "US",
            "retentionMode": "ZERO_RETENTION",
        });
        json!({
            "dataPolicy": {
                "state": "CONFIGURED",
                "processingRegion": "US",
                "retentionMode": "ZERO_RETENTION",
                "policyVersion": "relay-policy-v1",
                "policySha256": sha256(&canonical_bytes(&settings).expect("canonical policy")),
            }
        })
    }

    #[test]
    fn unconfigured_data_policy_fails_closed() {
        let result = RelayDataPolicy::from_routing_policy(
            &json!({"dataPolicy":{"state":"UNCONFIGURED"}}),
        );
        assert!(matches!(
            result,
            Err(Failure::Terminal(
                "PROVIDER_DATA_POLICY_UNCONFIGURED",
                _
            ))
        ));
        assert!(RelayDataPolicy::from_routing_policy(&policy()).is_ok());
    }

    #[test]
    fn relay_targets_require_https_and_exact_paths() {
        assert!(relay_target_has_path(
            "https://relay.example.test/v1/chat/completions",
            RELAY_CHAT_PATH,
        ));
        assert!(!relay_target_has_path(
            "http://relay.example.test/v1/chat/completions",
            RELAY_CHAT_PATH,
        ));
        assert!(!relay_target_has_path(
            "https://relay.example.test/v1/chat/completions?debug=true",
            RELAY_CHAT_PATH,
        ));

        let invalid_target = "http://relay.example.test/v1/chat/completions";
        assert!(matches!(
            validate_relay_target(invalid_target, RELAY_CHAT_PATH),
            Err(Failure::Terminal("PROVIDER_TARGET_INVALID", detail))
                if detail == invalid_target
        ));
    }
}
