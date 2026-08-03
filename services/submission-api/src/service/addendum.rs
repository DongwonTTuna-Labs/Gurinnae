use serde_json::{Map, Value, json};
use uuid::Uuid;

use super::{RequestContext, ServiceError};

/// Closed request boundary for the eight owner-addendum submission routes.
/// Unknown operation IDs never reach this dispatcher and unknown top-level
/// fields are rejected before any persistence or idempotency receipt is
/// touched.
pub async fn execute(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let payload = parse_payload(context.operation, context.body)?;
    let resource_id = context
        .attachment_id
        .or_else(|| {
            payload
                .get("appealId")
                .and_then(Value::as_str)
                .and_then(|v| Uuid::parse_str(v).ok())
        })
        .or_else(|| {
            payload
                .get("endpointId")
                .and_then(Value::as_str)
                .and_then(|v| Uuid::parse_str(v).ok())
        })
        .ok_or(ServiceError::Persistence)?;
    let operation = context.operation;
    if operation == "getResponseAppeal" {
        return Ok(json!({
            "operationId": operation,
            "id": resource_id,
            "status": "RECEIVED",
            "data": {},
            "links": []
        }));
    }
    let command = json!({
        "operationId": operation,
        "requestId": context.request_id,
        "status": "ACCEPTED",
        "aggregateId": resource_id,
        "aggregateVersion": 1,
        "acceptedAt": super::common::timestamp_now()?,
        "links": []
    });
    Ok(match operation {
        "createResponseAppeal" => {
            json!({"command": command, "appeal": {"id": resource_id, "state": "RECEIVED"}})
        }
        "unlinkCommunicationEndpoint" => {
            json!({"command": command, "endpoint": {"id": resource_id, "state": "REVOKED"}})
        }
        _ => return Err(ServiceError::InvalidRequest),
    })
}

fn parse_payload(operation: &str, body: &[u8]) -> Result<Map<String, Value>, ServiceError> {
    // The active authority defines endpoint/proof shapes but not the canonical
    // challenge producer/verifier ABI. Reject both halves before parsing secret
    // endpoint or proof bytes so this stub cannot claim PENDING or ACTIVE.
    if matches!(
        operation,
        "requestCommunicationEndpointLink" | "verifyCommunicationEndpointLink"
    ) {
        return Err(ServiceError::EndpointVerificationAuthorityIncomplete);
    }
    let payload = if body.is_empty() {
        Map::new()
    } else {
        serde_json::from_slice::<Value>(body)
            .map_err(|_| ServiceError::InvalidRequest)?
            .as_object()
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?
    };
    validate(operation, &payload)?;
    Ok(payload)
}

fn validate(operation: &str, payload: &Map<String, Value>) -> Result<(), ServiceError> {
    let required: &[&str] = match operation {
        "createResponseAppeal" => &[
            "expectedReceiptVersion",
            "reasonCode",
            "requestedOutcome",
            "statement",
            "supportingAttachmentIds",
            "attestation",
            "privacyConsent",
        ],
        "getResponseAppeal" => &["appealId"],
        "requestCommunicationEndpointLink" => &[
            "contractVersion",
            "endpoint",
            "linkingConsent",
            "expectedProfileVersion",
            "abuseProof",
        ],
        "verifyCommunicationEndpointLink" => &["challengeId", "proof", "expectedProfileVersion"],
        "unlinkCommunicationEndpoint" => &[
            "endpointId",
            "expectedEndpointVersion",
            "expectedProfileVersion",
            "reasonCode",
        ],
        _ => return Err(ServiceError::InvalidRequest),
    };
    for field in required {
        if !payload.contains_key(*field) {
            return Err(ServiceError::InvalidRequest);
        }
    }
    // Keep this list closed at the transport boundary. Nested values are
    // validated by their operation-specific domain handlers.
    let allowed: &[&str] = match operation {
        "createResponseAppeal" => required,
        "getResponseAppeal" => required,
        "requestCommunicationEndpointLink" => required,
        "verifyCommunicationEndpointLink" => required,
        "unlinkCommunicationEndpoint" => required,
        _ => &[],
    };
    if payload.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::Map;

    use super::{ServiceError, parse_payload, validate};

    #[test]
    fn endpoint_link_is_fail_closed_before_raw_endpoint_or_proof_parsing() {
        const RAW_ENDPOINT: &str = "person@example.invalid";
        const RAW_PROOF: &str = "raw-email-link-proof-must-never-leak-0001";
        let cases: [(&str, &[u8]); 2] = [
            (
                "requestCommunicationEndpointLink",
                br#"{"contractVersion":"communication-v1","endpoint":{"type":"EMAIL","address":"person@example.invalid"},"linkingConsent":{},"expectedProfileVersion":1,"abuseProof":{}}"#,
            ),
            (
                "verifyCommunicationEndpointLink",
                br#"{"challengeId":"00000000-0000-0000-0000-000000000001","proof":{"kind":"EMAIL_LINK","token":"raw-email-link-proof-must-never-leak-0001"},"expectedProfileVersion":1}"#,
            ),
        ];

        for (operation, body) in cases {
            let result = parse_payload(operation, body);
            assert!(matches!(
                &result,
                Err(ServiceError::EndpointVerificationAuthorityIncomplete)
            ));
            if let Err(error) = result {
                let rendered = error.to_string();
                assert!(!rendered.contains(RAW_ENDPOINT));
                assert!(!rendered.contains(RAW_PROOF));
                assert!(!rendered.contains("PENDING_VERIFICATION"));
                assert!(!rendered.contains("ACTIVE"));
            }
        }
    }

    #[test]
    fn privacy_operations_are_not_routable_through_the_generic_addendum_stub() {
        for operation in [
            "createPrivacyRequest",
            "exchangePrivacyRequestReceiptToken",
            "getPrivacyRequest",
        ] {
            assert!(matches!(
                validate(operation, &Map::new()),
                Err(ServiceError::InvalidRequest)
            ));
        }
    }
}
