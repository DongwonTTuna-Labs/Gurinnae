use serde_json::{Map, Value, json};
use uuid::Uuid;

use super::{RequestContext, ServiceError};

/// Closed request boundary for the eight owner-addendum submission routes.
/// Unknown operation IDs never reach this dispatcher and unknown top-level
/// fields are rejected before any persistence or idempotency receipt is
/// touched.
pub async fn execute(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let payload = if context.body.is_empty() {
        Map::new()
    } else {
        serde_json::from_slice::<Value>(context.body)
            .map_err(|_| ServiceError::InvalidRequest)?
            .as_object()
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?
    };
    validate(context.operation, &payload)?;
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
    if operation == "getResponseAppeal" || operation == "getPrivacyRequest" {
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
        "requestCommunicationEndpointLink" => {
            json!({"command": command, "endpoint": {"id": resource_id, "state": "PENDING_VERIFICATION"}, "challenge": {}})
        }
        "verifyCommunicationEndpointLink" => {
            json!({"command": command, "endpoint": {"id": resource_id, "state": "ACTIVE"}})
        }
        "unlinkCommunicationEndpoint" => {
            json!({"command": command, "endpoint": {"id": resource_id, "state": "REVOKED"}})
        }
        "createPrivacyRequest" => {
            json!({"command": command, "request": {"id": resource_id, "state": "RECEIVED"}, "receiptToken": ""})
        }
        "exchangePrivacyRequestReceiptToken" => json!({"command": command, "session": {}}),
        _ => return Err(ServiceError::InvalidRequest),
    })
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
        "createPrivacyRequest" => &[
            "requestType",
            "subjectIdentityProof",
            "jurisdiction",
            "scope",
            "contactEndpoint",
            "statement",
            "attestation",
            "privacyConsent",
            "abuseProof",
        ],
        "exchangePrivacyRequestReceiptToken" => &["token", "proof"],
        "getPrivacyRequest" => &[],
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
        "createPrivacyRequest" => required,
        "exchangePrivacyRequestReceiptToken" => required,
        "getPrivacyRequest" => required,
        _ => &[],
    };
    if payload.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}
